
--> 数据库基本信息

select now(),user(),current_user(),CONNECTION_ID(),DATABASE(),version(),all_db_size,@@basedir base_dit,@@datadir as data_dir,@@SOCKET as socket_dir,@@log_error as error_dir,@@AUTOCOMMIT as autocommit,@@log_bin as log_bin,@@server_id as  server_id from (SELECT concat(round(sum(DATA_LENGTH/1024/1024),2),'MB') as 'all_db_size' from information_schema.TABLES) tmp


-->版本信息
show variables like '%version_comment%';
show variables like '%version_compile_machine%';
show variables like '%version_compile_os%';


-->当前数据库实例的所有数据库及其容量大小

select SCHEMA_NAME,DEFAULT_CHARACTER_SET_NAME,DEFAULT_COLLATION_NAME,
sum(table_rows) as '记录数',
sum(truncate(data_length/1024/1024, 2)) as '数据容量(MB)',
sum(truncate(index_length/1024/1024, 2)) as '索引容量(MB)',
sum(truncate((data_length+index_length)/1024/1024, 2)) as '总大小(MB)',
sum(truncate(max_data_length/1024/1024, 2)) as '最大值(MB)'
from information_schema.SCHEMATA ma
left join information_schema.tables ta on ma.SCHEMA_NAME = ta.table_schema
group by SCHEMA_NAME
order by sum(data_length) desc, sum(index_length) desc;


-->数据库对象
select * from (
SELECT table_schema as '数据库','TABLE' as '对象类型', COUNT(*) as '对象数量' FROM information_schema.TABLES GROUP BY table_schema
union 
SELECT table_schema as '数据库','VIEW' as '对象类型', COUNT(*) as '对象数量' FROM information_schema.VIEWS GROUP BY table_schema
union 
SELECT db as '数据库','PROCEDURE' as '对象类型',COUNT(*) as '对象数量' FROM mysql.proc WHERE  `type` = 'PROCEDURE'  GROUP BY db
union
SELECT db as '数据库','FUNCTION' as '对象类型',COUNT(*) as '对象数量' FROM mysql.proc WHERE  `type` = 'FUNCTION'  GROUP BY db
) tmp order by 数据库,对象类型


-->查看数据库的运行状态
root@localhost 00:10 [(none)]> status
--------------
mysql  Ver 14.14 Distrib 5.7.24, for linux-glibc2.12 (x86_64) using  EditLine wrapper

Connection id:          16737
Current database:
Current user:           root@localhost
SSL:                    Not in use
Current pager:          stdout
Using outfile:          ''
Using delimiter:        ;
Server version:         5.7.24-log MySQL Community Server (GPL)
Protocol version:       10
Connection:             Localhost via UNIX socket
Server characterset:    utf8
Db     characterset:    utf8
Client characterset:    utf8
Conn.  characterset:    utf8
UNIX socket:            /data/mysql/mysql.sock
Uptime:                 27 days 10 hours 9 min 0 sec

Threads: 37  Questions: 3437291  Slow queries: 10  Opens: 57716  Flush tables: 1027  Open tables: 1016  Queries per second avg: 1.450
--------------


-->占用空间最大的前10张大表
select table_schema,table_name,table_type,engine,create_time,update_time,table_collation,
sum(table_rows) as '记录数',
sum(truncate(data_length/1024/1024, 2)) as '数据容量(MB)',
sum(truncate(index_length/1024/1024, 2)) as '索引容量(MB)',
sum(truncate((data_length+index_length)/1024/1024, 2)) as '总大小(MB)',
sum(truncate(max_data_length/1024/1024, 2)) as '最大值(MB)'
from information_schema.tables
where TABLE_SCHEMA not in('information_schema','sys','mysql','performance_schema')
group by table_schema,table_name
order by sum((data_length+index_length)) desc limit 10;


-->占用空间最大的前10个索引

select ta.table_schema,ta.table_name,st.index_name,sum(truncate(index_length/1024/1024, 2)) as 'SizeMB',st.NON_UNIQUE,st.INDEX_TYPE,st.COLUMN_NAME
from information_schema.tables ta
left join information_schema.STATISTICS st
on ta.table_schema = st.table_schema and ta.table_name = st.table_name
where ta.TABLE_SCHEMA not in('information_schema','sys','mysql','performance_schema')
group by ta.table_schema,ta.table_name
order by sum(index_length) desc limit 10;

-->所有存储引擎列表
SELECT * FROM information_schema.ENGINES order by ENGINE

--》查询所有用户
select * from mysql.user order by user

--》一些重要的参数
show variables like '%autocommit%';
show variables like '%datadir%';
show variables like '%innodb_buffer_pool_size%';
show variables like '%innodb_file_per_table%';
show variables like '%innodb_flush_log_at_trx_commit%';
show variables like '%innodb_io_capacity';
show variables like '%innodb_lock_wait_timeout%';
show variables like '%log_error';
show variables like '%log_output%';
show variables like '%log_queries_not_using_indexes%';
show variables like '%log_slave_updates%';
show variables like '%log_throttle_queries_not_using_indexes%';
show variables like '%long_query_time%';
show variables like '%lower_case_table_names%';
show variables like '%max_connect_errors%';
show variables like '%max_connections%';
show variables like '%max_user_connections%';
show variables like '%pid_file%';
show variables like '%query_cache_size%';
show variables like '%query_cache_type%';
show variables like '%read_only%';
show variables like '%server_id%';
show variables like '%slow_query_log%';
show variables like '%slow_query_log_file%';
show variables like '%socket%';
show variables like '%sql_mode%';
show variables like '%time_zone%';
show variables like '%tx_isolation%';


--》查看每个host的当前连接数和总连接数
select * from performance_schema.accounts order by user

-->查询执行过全扫描访问的表，默认情况下按照表扫描的行数进行降序排序(前10)
SELECT object_schema as db,
  object_name as table_name,
  count_read AS rows_full_scanned,
  sys.format_time(sum_timer_wait) AS execu_time
FROM performance_schema.table_io_waits_summary_by_index_usage
WHERE index_name IS NULL
AND count_read > 0
ORDER BY count_read DESC limit 10;

-->查看平均执行时间值大于95%的平均执行时间的语句（可近似地认为是平均执行时间超长的语句），默认情况下按照语句平均延迟(执行时间)降序排序(前10)
SELECT sys.format_statement(DIGEST_TEXT) AS query,
  SCHEMA_NAME as db,
  IF(SUM_NO_GOOD_INDEX_USED > 0 OR SUM_NO_INDEX_USED > 0, '*', '') AS full_scan,
  COUNT_STAR AS exec_count,
  SUM_ERRORS AS err_count,
  SUM_WARNINGS AS warn_count,
  sys.format_time(SUM_TIMER_WAIT) AS total_latency,
  sys.format_time(MAX_TIMER_WAIT) AS max_latency,
  sys.format_time(AVG_TIMER_WAIT) AS avg_latency,
  SUM_ROWS_SENT AS rows_sent,
  ROUND(IFNULL(SUM_ROWS_SENT / NULLIF(COUNT_STAR, 0), 0)) AS rows_sent_avg,
  SUM_ROWS_EXAMINED AS rows_examined,
  ROUND(IFNULL(SUM_ROWS_EXAMINED / NULLIF(COUNT_STAR, 0), 0)) AS rows_examined_avg,
  FIRST_SEEN AS first_seen,
  LAST_SEEN AS last_seen,
  DIGEST AS digest
FROM performance_schema.events_statements_summary_by_digest stmts
JOIN sys.x$ps_digest_95th_percentile_by_avg_us AS top_percentile
ON ROUND(stmts.avg_timer_wait/1000000) >= top_percentile.avg_us
ORDER BY AVG_TIMER_WAIT DESC limit 10;

-->查看产生错误或警告的语句，默认情况下，按照错误数量和警告数量降序排序(前10)
SELECT sys.format_statement(DIGEST_TEXT) AS query,
  SCHEMA_NAME as db,
  COUNT_STAR AS exec_count,
  SUM_ERRORS AS errors,
  IFNULL(SUM_ERRORS / NULLIF(COUNT_STAR, 0), 0) * 100 as error_pct,
  SUM_WARNINGS AS warnings,
  IFNULL(SUM_WARNINGS / NULLIF(COUNT_STAR, 0), 0) * 100 as warning_pct,
  FIRST_SEEN as first_seen,
  LAST_SEEN as last_seen,
  DIGEST AS digest
FROM performance_schema.events_statements_summary_by_digest
WHERE SUM_ERRORS > 0
OR SUM_WARNINGS > 0
ORDER BY SUM_ERRORS DESC, SUM_WARNINGS DESC limit 10;

-->查看全表扫描或者没有使用到最优索引的语句（前10）
SELECT sys.format_statement(DIGEST_TEXT) AS query,
  SCHEMA_NAME as db,
  COUNT_STAR AS exec_count,
  sys.format_time(SUM_TIMER_WAIT) AS total_latency,
  SUM_NO_INDEX_USED AS no_index_used_count,
  SUM_NO_GOOD_INDEX_USED AS no_good_index_used_count,
  ROUND(IFNULL(SUM_NO_INDEX_USED / NULLIF(COUNT_STAR, 0), 0) * 100) AS no_index_used_pct,
  SUM_ROWS_SENT AS rows_sent,
  SUM_ROWS_EXAMINED AS rows_examined,
  ROUND(SUM_ROWS_SENT/COUNT_STAR) AS rows_sent_avg,
  ROUND(SUM_ROWS_EXAMINED/COUNT_STAR) AS rows_examined_avg,
  FIRST_SEEN as first_seen,
  LAST_SEEN as last_seen,
  DIGEST AS digest
FROM performance_schema.events_statements_summary_by_digest
WHERE (SUM_NO_INDEX_USED > 0
OR SUM_NO_GOOD_INDEX_USED > 0)
AND DIGEST_TEXT NOT LIKE 'SHOW%'
ORDER BY no_index_used_pct DESC, total_latency DESC limit 10;


-->查看执行了文件排序的语句，默认情况下按照语句总延迟时间(执行时间)降序排序（前10）
SELECT sys.format_statement(DIGEST_TEXT) AS query,
  SCHEMA_NAME db,
  COUNT_STAR AS exec_count,
  sys.format_time(SUM_TIMER_WAIT) AS total_latency,
  SUM_SORT_MERGE_PASSES AS sort_merge_passes,
  ROUND(IFNULL(SUM_SORT_MERGE_PASSES / NULLIF(COUNT_STAR, 0), 0)) AS avg_sort_merges,
  SUM_SORT_SCAN AS sorts_using_scans,
  SUM_SORT_RANGE AS sort_using_range,
  SUM_SORT_ROWS AS rows_sorted,
  ROUND(IFNULL(SUM_SORT_ROWS / NULLIF(COUNT_STAR, 0), 0)) AS avg_rows_sorted,
  FIRST_SEEN as first_seen,
  LAST_SEEN as last_seen,
  DIGEST AS digest
FROM performance_schema.events_statements_summary_by_digest
WHERE SUM_SORT_ROWS > 0
ORDER BY SUM_TIMER_WAIT DESC limit 10;

-->查看使用了临时表的语句，默认情况下按照磁盘临时表数量和内存临时表数量进行降序排序（前10）
SELECT sys.format_statement(DIGEST_TEXT) AS query,
  SCHEMA_NAME as db,
  COUNT_STAR AS exec_count,
  sys.format_time(SUM_TIMER_WAIT) as total_latency,
  SUM_CREATED_TMP_TABLES AS memory_tmp_tables,
  SUM_CREATED_TMP_DISK_TABLES AS disk_tmp_tables,
  ROUND(IFNULL(SUM_CREATED_TMP_TABLES / NULLIF(COUNT_STAR, 0), 0)) AS avg_tmp_tables_per_query,
  ROUND(IFNULL(SUM_CREATED_TMP_DISK_TABLES / NULLIF(SUM_CREATED_TMP_TABLES, 0), 0) * 100) AS tmp_tables_to_disk_pct,
  FIRST_SEEN as first_seen,
  LAST_SEEN as last_seen,
  DIGEST AS digest
FROM performance_schema.events_statements_summary_by_digest
WHERE SUM_CREATED_TMP_TABLES > 0
ORDER BY SUM_CREATED_TMP_DISK_TABLES DESC, SUM_CREATED_TMP_TABLES DESC limit 10;


--> 性能参数统计
show status like 'Com_delete';
show status like 'Com_insert';
show status like 'Com_select';
show status like 'Connections';
show status like 'Created_tmp_disk_tables';
show status like 'Created_tmp_files';
show status like 'Created_tmp_tables';
show status like 'Handler_read_rnd_next';
show status like 'Open_files';
show status like 'Opened_tables';
show status like 'Slow_queries';
show status like 'Sort_merge_passes';
show status like 'Sort_range';
show status like 'Sort_rows';
show status like 'Sort_scan';
show status like 'Table_locks_immediate';
show status like 'Table_locks_waited';
show status like 'Uptime';
