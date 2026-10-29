/*
Azure SQL Managed Instance - Per-File I/O Performance Sampler

Measures SQL Server observed I/O activity for each database file.

Output:
- File size
- Sample count
- AVG / P50 / P75 / P95 / MAX IOPS
- AVG / P50 / P75 / P95 / MAX throughput (MB/s)

IOPS:
    Reads + Writes per second

Throughput:
    Bytes Read + Bytes Written per second

No Azure storage tier/limit comparison is performed.
*/

SET NOCOUNT ON;

BEGIN TRY

    ------------------------------------------------------------
    -- Parameters
    ------------------------------------------------------------
    -- Change sampling loop duration to collect data over a representative time interval
    DECLARE @LoopDurationSeconds int = 60;
    DECLARE @IntervalLengthMilliseconds int = 1000;

    IF @IntervalLengthMilliseconds < 100
        THROW 50001,
              'The minimum supported sampling interval duration is 100 ms.',
              1;

    ------------------------------------------------------------
    -- Initialize
    ------------------------------------------------------------
    DECLARE @StartDateTime datetime2(2) = SYSDATETIME();

    DECLARE @DelayInterval varchar(12) =
        CONVERT
        (
            varchar(12),
            DATEADD
            (
                millisecond,
                @IntervalLengthMilliseconds,
                CAST('00:00:00' AS time(3))
            ),
            114
        );

    ------------------------------------------------------------
    -- Sampling table
    ------------------------------------------------------------
    DECLARE @VFSSample TABLE
    (
        SampleMs       bigint   NOT NULL,
        DatabaseID     smallint NOT NULL,
        FileID         smallint NOT NULL,
        TransferCount  bigint   NOT NULL,
        ByteCount      bigint   NOT NULL,

        PRIMARY KEY
        (
            SampleMs,
            DatabaseID,
            FileID
        )
    );

    ------------------------------------------------------------
    -- Collect samples
    ------------------------------------------------------------
    WHILE SYSDATETIME() <
          DATEADD(second, @LoopDurationSeconds, @StartDateTime)
    BEGIN

        INSERT INTO @VFSSample
        (
            SampleMs,
            DatabaseID,
            FileID,
            TransferCount,
            ByteCount
        )
        SELECT
            vfs.sample_ms,
            vfs.database_id,
            vfs.file_id,

            vfs.num_of_reads +
            vfs.num_of_writes,

            vfs.num_of_bytes_read +
            vfs.num_of_bytes_written

        FROM sys.dm_io_virtual_file_stats(DEFAULT, DEFAULT) AS vfs

        -- Exclude databases/files residing on local storage
        WHERE vfs.database_id NOT IN
        (
            2,
            32760,
            32761,
            32762,
            32763
        );

        WAITFOR DELAY @DelayInterval;

    END;


    ------------------------------------------------------------
    -- Step 1
    -- Calculate change between consecutive samples
    ------------------------------------------------------------
    ;WITH SampleDelta AS
    (
        SELECT
            s.DatabaseID,
            s.FileID,
            s.SampleMs,

            LEAD(s.SampleMs)
                OVER
                (
                    PARTITION BY
                        s.DatabaseID,
                        s.FileID
                    ORDER BY
                        s.SampleMs
                ) AS NextSampleMs,

            LEAD(s.TransferCount)
                OVER
                (
                    PARTITION BY
                        s.DatabaseID,
                        s.FileID
                    ORDER BY
                        s.SampleMs
                )
                - s.TransferCount
                AS TransferDelta,

            LEAD(s.ByteCount)
                OVER
                (
                    PARTITION BY
                        s.DatabaseID,
                        s.FileID
                    ORDER BY
                        s.SampleMs
                )
                - s.ByteCount
                AS ByteDelta

        FROM @VFSSample AS s
    ),


    ------------------------------------------------------------
    -- Step 2
    -- Convert delta counters into IOPS and MB/s
    ------------------------------------------------------------
    IntervalPerf AS
    (
        SELECT
            sd.DatabaseID,
            sd.FileID,
            sd.SampleMs,

            ----------------------------------------------------
            -- IOPS
            ----------------------------------------------------
            CAST
            (
                sd.TransferDelta
                *
                (
                    1000.0 /
                    NULLIF
                    (
                        sd.NextSampleMs - sd.SampleMs,
                        0
                    )
                )
                AS decimal(18,2)
            ) AS IOPS,


            ----------------------------------------------------
            -- Throughput MB/s
            ----------------------------------------------------
            CAST
            (
                (
                    sd.ByteDelta
                    /
                    (
                        NULLIF
                        (
                            sd.NextSampleMs - sd.SampleMs,
                            0
                        )
                        * 0.001
                    )
                )
                / 1024.0
                / 1024.0

                AS decimal(18,2)
            ) AS ThroughputMBPS

        FROM SampleDelta AS sd

        WHERE
            sd.NextSampleMs IS NOT NULL

            -- Protect against counter reset / invalid sample
            AND sd.TransferDelta >= 0
            AND sd.ByteDelta >= 0

            -- Protect against zero elapsed time
            AND sd.NextSampleMs > sd.SampleMs
    ),


    ------------------------------------------------------------
    -- Step 3
    -- Add database/file information
    ------------------------------------------------------------
    FilePerf AS
    (
        SELECT
            ip.DatabaseID,
            ip.FileID,

            DB_NAME(ip.DatabaseID)
                AS DatabaseName,

            mf.name
                AS FileLogicalName,

            mf.physical_name
                AS FilePhysicalName,

            mf.type_desc
                AS FileType,

            CAST
            (
                mf.size * 8.0 / 1024 / 1024
                AS decimal(18,2)
            ) AS FileSizeGB,

            ip.SampleMs,
            ip.IOPS,
            ip.ThroughputMBPS

        FROM IntervalPerf AS ip

        INNER JOIN sys.master_files AS mf
            ON ip.DatabaseID = mf.database_id
           AND ip.FileID = mf.file_id
    ),


    ------------------------------------------------------------
    -- Step 4
    -- Calculate percentiles
    ------------------------------------------------------------
    PercentilePerf AS
    (
        SELECT
            fp.*,


            ----------------------------------------------------
            -- IOPS Percentiles
            ----------------------------------------------------
            PERCENTILE_CONT(0.50)
                WITHIN GROUP
                (
                    ORDER BY fp.IOPS
                )
                OVER
                (
                    PARTITION BY
                        fp.DatabaseID,
                        fp.FileID
                )
                AS P50_IOPS,


            PERCENTILE_CONT(0.75)
                WITHIN GROUP
                (
                    ORDER BY fp.IOPS
                )
                OVER
                (
                    PARTITION BY
                        fp.DatabaseID,
                        fp.FileID
                )
                AS P75_IOPS,


            PERCENTILE_CONT(0.95)
                WITHIN GROUP
                (
                    ORDER BY fp.IOPS
                )
                OVER
                (
                    PARTITION BY
                        fp.DatabaseID,
                        fp.FileID
                )
                AS P95_IOPS,


            ----------------------------------------------------
            -- Throughput Percentiles
            ----------------------------------------------------
            PERCENTILE_CONT(0.50)
                WITHIN GROUP
                (
                    ORDER BY fp.ThroughputMBPS
                )
                OVER
                (
                    PARTITION BY
                        fp.DatabaseID,
                        fp.FileID
                )
                AS P50_ThroughputMBPS,


            PERCENTILE_CONT(0.75)
                WITHIN GROUP
                (
                    ORDER BY fp.ThroughputMBPS
                )
                OVER
                (
                    PARTITION BY
                        fp.DatabaseID,
                        fp.FileID
                )
                AS P75_ThroughputMBPS,


            PERCENTILE_CONT(0.95)
                WITHIN GROUP
                (
                    ORDER BY fp.ThroughputMBPS
                )
                OVER
                (
                    PARTITION BY
                        fp.DatabaseID,
                        fp.FileID
                )
                AS P95_ThroughputMBPS

        FROM FilePerf AS fp
    )


    ------------------------------------------------------------
    -- Final output
    ------------------------------------------------------------
    SELECT
        DatabaseName,
        FileLogicalName,
        FilePhysicalName,
        FileType,
        FileSizeGB,

        COUNT(*) AS SampleCount,


        --------------------------------------------------------
        -- IOPS
        --------------------------------------------------------
        CAST
        (
            AVG(IOPS)
            AS decimal(18,2)
        ) AS AvgIOPS,

        CAST
        (
            MAX(P50_IOPS)
            AS decimal(18,2)
        ) AS P50_IOPS,

        CAST
        (
            MAX(P75_IOPS)
            AS decimal(18,2)
        ) AS P75_IOPS,

        CAST
        (
            MAX(P95_IOPS)
            AS decimal(18,2)
        ) AS P95_IOPS,

        CAST
        (
            MAX(IOPS)
            AS decimal(18,2)
        ) AS MaxIOPS,


        --------------------------------------------------------
        -- Throughput MB/s
        --------------------------------------------------------
        CAST
        (
            AVG(ThroughputMBPS)
            AS decimal(18,2)
        ) AS AvgMBPS,

        CAST
        (
            MAX(P50_ThroughputMBPS)
            AS decimal(18,2)
        ) AS P50_MBPS,

        CAST
        (
            MAX(P75_ThroughputMBPS)
            AS decimal(18,2)
        ) AS P75_MBPS,

        CAST
        (
            MAX(P95_ThroughputMBPS)
            AS decimal(18,2)
        ) AS P95_MBPS,

        CAST
        (
            MAX(ThroughputMBPS)
            AS decimal(18,2)
        ) AS MaxMBPS

    FROM PercentilePerf

    GROUP BY
        DatabaseID,
        FileID,
        DatabaseName,
        FileLogicalName,
        FilePhysicalName,
        FileType,
        FileSizeGB

    ORDER BY
        DatabaseName,
        FileLogicalName;


END TRY

BEGIN CATCH

    THROW;

END CATCH;
