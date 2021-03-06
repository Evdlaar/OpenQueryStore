/*********************************************************************************************
Open Query Store
v0.1

Copyright:
William Durkin (@sql_williamd) / Enrico van de Laar (@evdlaar)

https://github.com/OpenQueryStore/OpenQueryStore

License: 
	This script is free to download and use for personal, educational, and internal 
	corporate purposes, provided that this header is preserved. Redistribution or sale 
	of this script, in whole or in part, is prohibited without the author's express 
	written consent.

	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, 
	INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. 
	IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES 
	OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, 
	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

**********************************************************************************************/


SET ANSI_NULLS ON;
GO

SET QUOTED_IDENTIFIER ON;
GO

-- Enable the Service Broker for the user database
DECLARE @db sysname

IF (SELECT [is_broker_enabled]
      FROM [sys].[databases]
     WHERE [database_id] = DB_ID()) = 0
BEGIN
	SET @db = DB_NAME()
	EXEC ('ALTER DATABASE '+@db+' SET ENABLE_BROKER')
    ;
END;

-- Create the OQS Schema
IF NOT EXISTS (SELECT *
                 FROM [sys].[schemas] AS [S]
                WHERE [S].[name] = 'oqs')
BEGIN
    EXEC ('CREATE SCHEMA oqs');
END;

-- Create the metadata storage table
IF EXISTS (SELECT *
             FROM [sys].[tables] AS [T]
            WHERE [T].[object_id] = OBJECT_ID(N'[oqs].[CollectionMetaData]'))
BEGIN
    DROP TABLE [oqs].[CollectionMetaData];
END;

CREATE TABLE [oqs].[CollectionMetaData] (
    [Command] NVARCHAR(2000), -- The command that should be executed by Service Broker
    [CollectionInterval] BIGINT NULL, -- The interval for looped processing (in seconds)
	);
GO

INSERT INTO [oqs].[CollectionMetaData] ([Command],
                                        [CollectionInterval])
VALUES (N'EXEC [oqs].[Gather_Statistics] @logmode=1',
        60);

-- Create the Service Broker structure
CREATE QUEUE [OQSScheduler];
CREATE SERVICE [OQSService] ON QUEUE [dbo].[OQSScheduler] ([DEFAULT]);
GO

CREATE PROCEDURE [oqs].[ActivateOQSScheduler] WITH EXECUTE AS OWNER
	AS
	BEGIN
		DECLARE @Handle UNIQUEIDENTIFIER,
				@Type   sysname,
				@msg    NVARCHAR(MAX);
		WAITFOR (RECEIVE TOP (1) @Handle = [conversation_handle],
								 @Type = [message_type_name]
				 FROM [dbo].[OQSScheduler]),
		TIMEOUT 5000; -- wait for 5 seconds
		IF @Handle IS NULL -- no message received
			RETURN;
		IF @Type = 'http://schemas.microsoft.com/SQL/ServiceBroker/DialogTimer' -- This is the timer loop for "normal" operation
		BEGIN
			-- Grab the configuration
			DECLARE @Command            NVARCHAR(2000),
					@CollectionInterval BIGINT;
			SELECT @Command = [CMD].[Command],
				   @CollectionInterval = [CMD].[CollectionInterval]
			  FROM [oqs].[CollectionMetaData] AS [CMD];

			-- Place the command into a delayed execution
			BEGIN CONVERSATION TIMER (@Handle) TIMEOUT = @CollectionInterval;
			EXEC (@Command);

		END;
		ELSE
			END CONVERSATION @Handle;
	END;
GO

ALTER QUEUE [dbo].[OQSScheduler]
WITH STATUS = ON,
     RETENTION = OFF,
     ACTIVATION (STATUS = ON,
                 PROCEDURE_NAME = [oqs].[ActivateOQSScheduler],
                 MAX_QUEUE_READERS = 1,
                 EXECUTE AS OWNER);
GO

CREATE PROCEDURE oqs.[StartScheduler]
AS
BEGIN
    DECLARE @handle UNIQUEIDENTIFIER;
    SELECT @handle = [conversation_handle]
      FROM [sys].[conversation_endpoints]
     WHERE [is_initiator] = 1
       AND [far_service]  = 'OQSService'
       AND [state]        <> 'CD';
    IF @@ROWCOUNT = 0
    BEGIN
        BEGIN DIALOG CONVERSATION @handle
        FROM SERVICE [OQSService]
        TO SERVICE 'OQSService'
        ON CONTRACT [DEFAULT]
        WITH ENCRYPTION = OFF;

        BEGIN CONVERSATION TIMER (@handle) TIMEOUT = 1;
    END;
END;
GO

CREATE PROCEDURE oqs.[StopScheduler]
AS
BEGIN
    DECLARE @handle UNIQUEIDENTIFIER;
    SELECT @handle = [conversation_handle]
      FROM [sys].[conversation_endpoints]
     WHERE [is_initiator] = 1
       AND [far_service]  = 'OQSService'
       AND [state]        <> 'CD';
    IF @@ROWCOUNT <> 0
        END CONVERSATION @handle;
END;

-- Create the OQS tables inside the oqs schema
CREATE TABLE [oqs].[Intervals](
	[Interval_id] [int] IDENTITY(1,1) NOT NULL,
	[Interval_start] [datetime] NULL,
	[Interval_end] [datetime] NULL
) ON [PRIMARY]
GO

-- Create plans table
CREATE TABLE [oqs].[Plans](
	[plan_id] [int] IDENTITY(1,1) NOT NULL,
	[plan_handle] [varbinary](64) NULL,
	[plan_firstfound] [datetime] NULL,
	[plan_database] [nvarchar](150) NULL,
	[plan_refcounts] [int] NULL,
	[plan_usecounts] [int] NULL,
	[plan_sizeinbytes] [int] NULL,
	[plan_type] [nvarchar](50) NULL,
	[plan_objecttype] [nvarchar](20) NULL,
	[plan_executionplan] [xml] NULL
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO

-- Create the queries table
CREATE TABLE [oqs].[Queries](
	[query_id] [int] IDENTITY(1,1) NOT NULL,
	[plan_id] [int] NOT NULL,
	[query_hash] [binary](8) NULL,
	[query_statement_text] [nvarchar](max) NULL,
	[query_statement_start_offset] [int] NULL,
	[query_statement_end_offset] [int] NULL,
	[query_creation_time] [datetime] NULL
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO

-- Create the Runtime Statistics table
CREATE TABLE [oqs].[Query_Runtime_Stats](
	[query_id] [int] NULL,
	[interval_id] [int] NULL,
	[creation_time] [datetime] NULL,
	[last_execution_time] [datetime] NULL,
	[execution_count] [bigint] NULL,
	[total_elapsed_time] [bigint] NULL,
	[last_elapsed_time] [bigint] NULL,
	[min_elapsed_time] [bigint] NULL,
	[max_elapsed_time] [bigint] NULL,
	[avg_elapsed_time] [bigint] NULL,
	[total_rows] [bigint] NULL,
	[last_rows] [bigint] NULL,
	[min_rows] [bigint] NULL,
	[max_rows] [bigint] NULL,
	[avg_rows] [bigint] NULL,
	[total_worker_time] [bigint] NULL,
	[last_worker_time] [bigint] NULL,
	[min_worker_time] [bigint] NULL,
	[max_worker_time] [bigint] NULL,
	[avg_worker_time] [bigint] NULL,
	[total_physical_reads] [bigint] NULL,
	[last_physical_reads] [bigint] NULL,
	[min_physical_reads] [bigint] NULL,
	[max_physical_reads] [bigint] NULL,
	[avg_physical_reads] [bigint] NULL,
	[total_logical_reads] [bigint] NULL,
	[last_logical_reads] [bigint] NULL,
	[min_logical_reads] [bigint] NULL,
	[max_logical_reads] [bigint] NULL,
	[avg_logical_reads] [bigint] NULL,
	[total_logical_writes] [bigint] NULL,
	[last_logical_writes] [bigint] NULL,
	[min_logical_writes] [bigint] NULL,
	[max_logical_writes] [bigint] NULL,
	[avg_logical_writes] [bigint] NULL
) ON [PRIMARY]
GO

-- Create logging table
CREATE TABLE [oqs].[Log](
	[Log_LogID] [int] IDENTITY(1,1) NOT NULL,
	[Log_LogRunID] [int] NULL,
	[Log_DateTime] [datetime] NULL,
	[Log_Message] [varchar](250) NULL
) ON [PRIMARY]
GO

-- Create the OQS Gather_Statistics Stored Procedure
ALTER PROCEDURE [oqs].[Gather_Statistics]
	@debug INT = 0,
	@logmode INT = 0

	AS

	DECLARE @log_logrunid INT
	DECLARE @log_newplans INT
	DECLARE @log_newqueries INT

	BEGIN
		
		IF @logmode = 1
			BEGIN
				SET @log_logrunid = (SELECT ISNULL(MAX(Log_LogRunID),0)+1 FROM [oqs].[Log])
			END

		IF @logmode =  1
			BEGIN
				INSERT INTO [oqs].[Log] (Log_LogRunID, Log_DateTime, Log_Message) VALUES (@log_logrunid, GETDATE(), 'OpenQueryStore capture script started...')
			END

		-- Create a new interval
		INSERT INTO [oqs].[Intervals]
			(
			Interval_start
			)
		VALUES
			(
			GETDATE()
			)

		-- Start execution plan insertion
		-- Get plans from the plan cache that do not exist in the OQS_Plans table
		-- for the database on the current context
		INSERT INTO [oqs].[Plans]
			(
			plan_handle,
			plan_firstfound,
			plan_database,
			plan_refcounts,
			plan_usecounts,
			plan_sizeinbytes,
			plan_type,
			plan_objecttype,
			plan_executionplan
			)
		SELECT 
			cp.plan_handle,
			GETDATE(),
			DB_NAME(qp.[dbid]),
			cp.refcounts,
			cp.usecounts,
			cp.size_in_bytes,
			cp.cacheobjtype,
			cp.objtype,
			qp.query_plan
		FROM sys.dm_exec_cached_plans cp
		CROSS APPLY sys.dm_exec_query_plan (cp.plan_handle) qp
		WHERE cacheobjtype = 'Compiled Plan'
		AND (qp.query_plan IS NOT NULL AND DB_NAME(qp.[dbid]) IS NOT NULL)
		AND cp.plan_handle NOT IN (SELECT plan_handle FROM [oqs].[Plans])
		AND qp.[dbid] = DB_ID()

		SET @log_newplans = @@ROWCOUNT

		IF @logmode =  1
			BEGIN
				INSERT INTO [oqs].[Log] (Log_LogRunID, Log_DateTime, Log_Message) VALUES (@log_logrunid, GETDATE(), 'OpenQueryStore captured ' + CONVERT(varchar, @log_newplans) + ' new plan(s)...')
			END

		-- Grab all of the queries (statement level) that are connected to the plans inside the OQS
		;WITH CTE_Queries (plan_id, plan_handle)
		AS
			(
			SELECT
				plan_id,
				plan_handle
			FROM [oqs].[Plans]
			)
		INSERT INTO [oqs].[Queries]
			(
			plan_id,
			query_hash,
			query_statement_text,
			query_statement_start_offset,
			query_statement_end_offset,
			query_creation_time
			)
		SELECT
			cte.plan_id,
			qs.query_hash,
			SUBSTRING
				(
				st.text, (qs.statement_start_offset/2)+1,   
					(
						(
						CASE qs.statement_end_offset  
							WHEN -1 THEN DATALENGTH(st.text)  
							ELSE qs.statement_end_offset  
						END - qs.statement_start_offset
						)/2
					) + 1
				) 
			AS statement_text,
			qs.statement_start_offset,
			qs.statement_end_offset,
			qs.creation_time 
		FROM CTE_Queries cte
		INNER JOIN sys.dm_exec_query_stats qs
		ON cte.plan_handle = qs.plan_handle
		CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
		WHERE qs.query_hash NOT IN (SELECT query_hash FROM [oqs].[Queries])

		SET @log_newqueries = @@ROWCOUNT

		IF @logmode =  1
			BEGIN
				INSERT INTO [oqs].[Log] (Log_LogRunID, Log_DateTime, Log_Message) VALUES (@log_logrunid, GETDATE(), 'OpenQueryStore captured ' + CONVERT(varchar, @log_newqueries) + ' new queries...')
			END

		-- Grab the interval_id of the interval we added at the beginning
		DECLARE @Interval_ID INT = IDENT_CURRENT('[oqs].[Intervals]')

		-- Insert runtime statistics for every query statement that is recorded inside the OQS
		INSERT INTO [oqs].[Query_Runtime_Stats]
				   ([query_id]
				   ,[interval_id]
				   ,[creation_time]
				   ,[last_execution_time]
				   ,[execution_count]
				   ,[total_elapsed_time]
				   ,[last_elapsed_time]
				   ,[min_elapsed_time]
				   ,[max_elapsed_time]
				   ,[avg_elapsed_time]
				   ,[total_rows]
				   ,[last_rows]
				   ,[min_rows]
				   ,[max_rows]
				   ,[avg_rows]
				   ,[total_worker_time]
				   ,[last_worker_time]
				   ,[min_worker_time]
				   ,[max_worker_time]
				   ,[avg_worker_time]
				   ,[total_physical_reads]
				   ,[last_physical_reads]
				   ,[min_physical_reads]
				   ,[max_physical_reads]
				   ,[avg_physical_reads]
				   ,[total_logical_reads]
				   ,[last_logical_reads]
				   ,[min_logical_reads]
				   ,[max_logical_reads]
				   ,[avg_logical_reads]
				   ,[total_logical_writes]
				   ,[last_logical_writes]
				   ,[min_logical_writes]
				   ,[max_logical_writes]
				   ,[avg_logical_writes]
				   )
		SELECT
			oqs_q.query_id,
			@Interval_ID,
			qs.creation_time,
			qs.last_execution_time,
			qs.execution_count,
			qs.total_elapsed_time,
			qs.last_elapsed_time,
			qs.min_elapsed_time,
			qs.max_elapsed_time,
			0,
			qs.total_rows,
			qs.last_rows,
			qs.min_rows,
			qs.max_rows,
			0,
			qs.total_worker_time,
			qs.last_worker_time,
			qs.min_worker_time,
			qs.max_worker_time,
			0,
			qs.total_physical_reads,
			qs.last_physical_reads,
			qs.min_physical_reads,
			qs.max_physical_reads,
			0,
			qs.total_logical_reads,
			qs.last_logical_reads,
			qs.min_logical_reads,
			qs.max_logical_reads,
			0,
			qs.total_logical_writes,
			qs.last_logical_writes,
			qs.min_logical_writes,
			qs.max_logical_writes,
			0
		FROM [oqs].[Queries] oqs_q
		INNER join sys.dm_exec_query_stats qs
		ON (oqs_q.query_hash = qs.query_hash AND oqs_q.query_statement_start_offset = qs.statement_start_offset AND oqs_q.query_statement_end_offset = qs.statement_end_offset AND oqs_q.query_creation_time = qs.creation_time)

		-- DEBUG: Get current info of the QRS table
		IF @debug =  1
			BEGIN
				SELECT 'Snapshot of captured runtime statistics'
				SELECT * FROM [oqs].[Query_Runtime_Stats]
			END

		-- Close the interval now that the statistics are in
		UPDATE [oqs].[Intervals]
		SET Interval_end = GETDATE() WHERE Interval_id = (SELECT MAX(Interval_id)-1 FROM [oqs].[Intervals])

		-- Now that we have the runtime statistics inside the OQS we need to perform some calculations
		-- so we can see query performance per interval captured

		-- First thing we need is a temporary table to hold our calculated deltas
		IF OBJECT_ID('tempdb..#OQS_Runtime_Stats') IS NOT NULL
			BEGIN
				DROP TABLE #OQS_Runtime_Stats
			END

		-- Calculate deltas and insert them in the temp table
		;WITH CTE_Update_Runtime_Stats 
			(
			query_id, 
			interval_id,
			execution_count, 
			total_elapsed_time, 
			total_rows,
			total_worker_time,
			total_physical_reads,
			total_logical_reads,
			total_logical_writes
			)
			AS
				(
				SELECT
					query_id,
					interval_id,
					execution_count,
					total_elapsed_time,
					total_rows,
					total_worker_time,
					total_physical_reads,
					total_logical_reads,
					total_logical_writes
				FROM [oqs].[Query_Runtime_Stats]
				WHERE interval_id = (SELECT MAX(Interval_id)-1 FROM [oqs].[Intervals])
				)
		SELECT
			cte.query_id,
			cte.interval_id,
			(qrs.execution_count - cte.execution_count) AS 'Delta Exec Count',
			(qrs.total_elapsed_time - cte.total_elapsed_time) AS 'Delta Time',
			ISNULL(((qrs.total_elapsed_time - cte.total_elapsed_time)/nullif((qrs.execution_count - cte.execution_count),0)),0) AS 'Avg. Time',
			(qrs.total_rows - cte.total_rows) AS 'Delta Total Rows',
			ISNULL(((qrs.total_rows - cte.total_rows)/nullif((qrs.execution_count - cte.execution_count),0)),0) AS 'Avg. Rows',
			(qrs.total_worker_time - cte.total_worker_time) AS 'Delta Total Worker Time',
			ISNULL(((qrs.total_worker_time - cte.total_worker_time)/nullif((qrs.execution_count - cte.execution_count),0)),0) AS 'Avg. Worker Time',
			(qrs.total_physical_reads - cte.total_physical_reads) AS 'Delta Total Phys Reads',
			ISNULL(((qrs.total_physical_reads - cte.total_physical_reads)/nullif((qrs.execution_count - cte.execution_count),0)),0) AS 'Avg. Phys reads',
			(qrs.total_logical_reads - cte.total_logical_reads) AS 'Delta Total Log Reads',
			ISNULL(((qrs.total_logical_reads - cte.total_logical_reads)/nullif((qrs.execution_count - cte.execution_count),0)),0) AS 'Avg. Log reads',
			(qrs.total_logical_writes - cte.total_logical_writes) AS 'Delta Total Log Writes',
			ISNULL(((qrs.total_logical_writes - cte.total_logical_writes)/nullif((qrs.execution_count - cte.execution_count),0)),0) AS 'Avg. Log writes'
		INTO #OQS_Runtime_Stats
		FROM CTE_Update_Runtime_Stats cte
		INNER JOIN [oqs].[Query_Runtime_Stats] qrs
		ON cte.query_id = qrs.query_id
		WHERE qrs.interval_id = (SELECT MAX(Interval_id) FROM [oqs].[Intervals])

		IF @debug =  1
			BEGIN
				SELECT 'Snapshot of runtime statistics deltas'
				SELECT * FROM #OQS_Runtime_Stats
			END

		-- Update the runtime statistics of the queries captured in the previous interval
		-- with the delta runtime information
		UPDATE qrs
			SET 
				qrs.execution_count = tqrs.[Delta Exec Count],
				qrs.total_elapsed_time = tqrs.[Delta Time],
				qrs.avg_elapsed_time = tqrs.[Avg. Time],
				qrs.total_rows = tqrs.[Delta Total Rows],
				qrs.avg_rows = tqrs.[Avg. Rows],
				qrs.total_worker_time = tqrs.[Delta Total Worker Time],
				qrs.avg_worker_time = tqrs.[Avg. Worker Time],
				qrs.total_physical_reads = tqrs.[Delta Total Phys Reads],
				qrs.avg_physical_reads = tqrs.[Avg. Phys reads],
				qrs.total_logical_reads = tqrs.[Delta Total Log Reads],
				qrs.avg_logical_reads = tqrs.[Avg. Log reads],
				qrs.total_logical_writes = tqrs.[Delta Total Log Writes],
				qrs.avg_logical_writes = tqrs.[Avg. Log writes]
			FROM [oqs].[Query_Runtime_Stats] qrs
			INNER JOIN #OQS_Runtime_Stats tqrs
			ON (qrs.interval_id = tqrs.interval_id AND qrs.query_id = tqrs.query_id)

		IF @debug =  1
			BEGIN
				SELECT 'Snapshot of runtime statistics after delta update'
				SELECT * FROM [oqs].[Query_Runtime_Stats]
			END
	
	-- And we are done!
	IF @logmode =  1
		BEGIN
			INSERT INTO [oqs].[Log] (Log_LogRunID, Log_DateTime, Log_Message) VALUES (@log_logrunid, GETDATE(), 'OpenQueryStore capture script finished...')
		END

	END
	
GO

-- Finished installation!



