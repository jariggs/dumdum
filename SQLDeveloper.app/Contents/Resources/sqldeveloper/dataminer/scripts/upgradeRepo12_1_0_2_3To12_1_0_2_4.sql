ALTER session set current_schema = "ODMRSYS";

@@version.sql

DEFINE OLD_REPOSITORY_VERSION = '12.1.0.2.3'
DEFINE NEW_REPOSITORY_VERSION = '12.1.0.2.4'

EXECUTE dbms_output.put_line('Start repository upgrade from ' || '&OLD_REPOSITORY_VERSION' || ' to ' || '&NEW_REPOSITORY_VERSION' || '. ' || systimestamp);

DECLARE
  REPOS_VERSION VARCHAR2(30);
  DB_VER VARCHAR2(30);
BEGIN
  SELECT PROPERTY_STR_VALUE INTO REPOS_VERSION FROM ODMRSYS.ODMR$REPOSITORY_PROPERTIES WHERE PROPERTY_NAME = 'VERSION';
  SELECT VERSION INTO DB_VER FROM PRODUCT_COMPONENT_VERSION WHERE PRODUCT LIKE 'Oracle Database%' OR PRODUCT LIKE 'Personal Oracle Database %';
  IF ( repos_version = '&OLD_REPOSITORY_VERSION' ) THEN

    EXECUTE IMMEDIATE 'DELETE ODMRSYS.ODMR$REPOSITORY_PROPERTIES WHERE PROPERTY_NAME = ''MAX_WORKFLOW_LOG_COUNT''';
    EXECUTE IMMEDIATE 'INSERT INTO ODMRSYS.ODMR$REPOSITORY_PROPERTIES (PROPERTY_NAME, PROPERTY_NUM_VALUE, "COMMENT") VALUES (''POLLING_IDLE_RATE'', 0, ''Rate (in milliseconds) at which the Data Miner client will poll the database when there are no workflows detected running'')';
    EXECUTE IMMEDIATE 'INSERT INTO ODMRSYS.ODMR$REPOSITORY_PROPERTIES (PROPERTY_NAME, PROPERTY_NUM_VALUE, "COMMENT") VALUES (''POLLING_ACTIVE_RATE'', 0, ''Rate (in milliseconds) at which the Data Miner client will poll the database when there are workflows detected running'')';
    EXECUTE IMMEDIATE 'INSERT INTO ODMRSYS.ODMR$REPOSITORY_PROPERTIES (PROPERTY_NAME, PROPERTY_NUM_VALUE, "COMMENT") VALUES (''POLLING_COMPLETED_WINDOW'', 0, ''The window of time (in hours) to include completed workflows in the polling query result'')';
    EXECUTE IMMEDIATE 'INSERT INTO ODMRSYS.ODMR$REPOSITORY_PROPERTIES (PROPERTY_NAME, PROPERTY_STR_VALUE, "COMMENT") VALUES (''PURGE_WORKFLOW_SCHEDULER_OBJS'', ''TRUE'', ''Purges (TRUE or FALSE) old Oracle Scheduler objects generated by the running of Data Miner workflows'')';
    EXECUTE IMMEDIATE 'INSERT INTO ODMRSYS.ODMR$REPOSITORY_PROPERTIES (PROPERTY_NAME, PROPERTY_NUM_VALUE, "COMMENT") VALUES (''PURGE_WORKFLOW_EVENT_LOG'', 5, ''Controls how many workflows runs are preserved for each workflow in the event log. The older workflows events are purged to keep within this limit'')';
    COMMIT;
    
    BEGIN
      EXECUTE IMMEDIATE 'drop TABLE ODMRSYS.ODMR$WORKFLOW_RUN_NODES PURGE' ;
      EXCEPTION
      WHEN OTHERS THEN
        NULL;
    END;
    EXECUTE IMMEDIATE 'CREATE TABLE ODMRSYS.ODMR$WORKFLOW_RUN_NODES
      (
        WORKFLOW_JOB_ID VARCHAR2(128) NOT NULL
      , NODE_ID VARCHAR2(30) NOT NULL
      , SUBNODE_ID VARCHAR2(30)
      , CONSTRAINT ODMR$WORKFLOW_RUN_NODES_UNIQUE UNIQUE
        (
          WORKFLOW_JOB_ID,
          NODE_ID,
          SUBNODE_ID
        )
        ENABLE 
      ) 
      LOGGING 
      PCTFREE 10 
      INITRANS 1 
      STORAGE 
      ( 
        INITIAL 65536 
        MINEXTENTS 1 
        MAXEXTENTS 2147483645 
        BUFFER_POOL DEFAULT 
      )';

    EXECUTE IMMEDIATE 'ALTER TABLE ODMRSYS.ODMR$WORKFLOW_RUN_NODES
      ADD CONSTRAINT ODMR$WORKFLOW_RUN_NODES_FK FOREIGN KEY
      (
        WORKFLOW_JOB_ID
      )
      REFERENCES ODMRSYS.ODMR$WORKFLOW_JOBS
      (
        WORKFLOW_JOB_ID 
      )
      ON DELETE CASCADE ENABLE';
    
    EXECUTE IMMEDIATE 'CREATE OR REPLACE VIEW ODMRSYS.ODMR_ALL_WORKFLOW_ALL_POLL AS SELECT * FROM
      (
      WITH A AS
      (
        SELECT USER_NAME, WORKFLOW_JOB_ID "WF_JOB_NAME", PROJ_ID, WF_ID, NODE_ID, SUBNODE_ID, log_subtype, log_task,
        CASE WHEN NODE_ID = ''WF_START'' THEN ''11000001''
             WHEN log_type IS NULL THEN ''00000000''
             WHEN log_type = ''INFO'' AND log_subtype = ''START'' THEN ''10000001''
             WHEN log_type = ''WARN'' AND log_subtype = ''START'' THEN ''10000010''
             WHEN log_type = ''ERR'' AND log_subtype = ''START'' THEN ''10000100''
             WHEN log_type = ''INFO'' AND log_subtype = ''END'' THEN ''01000001''
             WHEN log_type = ''WARN'' AND log_subtype = ''END'' THEN ''01000010''
             WHEN log_type = ''ERR'' AND log_subtype = ''END'' THEN ''01000100''
        ELSE NULL
        END "ENCODE_STATUS",
        CASE WHEN log_subtype = ''START'' THEN
         log_timestamp
        ELSE null
        END "NODE_START_TIME",
        CASE WHEN log_subtype = ''END'' THEN
         log_duration
        ELSE null
        END "NODE_RUN_TIME"
        FROM (    
          SELECT l.USER_NAME, n.WORKFLOW_JOB_ID, l.PROJ_ID, l.WF_ID, n.NODE_ID,n.SUBNODE_ID,
          l.log_subtype, l.log_task, l.log_type, l.log_duration, l.log_timestamp
          FROM 
          (
            SELECT DISTINCT WORKFLOW_JOB_ID, NODE_ID, 
            CASE WHEN SUBNODE_ID = ''E'' THEN NULL
            WHEN SUBNODE_ID = ''X'' THEN NULL
            ELSE SUBNODE_ID
            END "SUBNODE_ID",
            CASE WHEN SUBNODE_ID = ''E'' THEN (NODE_ID||''$''||NULL)
            WHEN SUBNODE_ID = ''X'' THEN (NODE_ID||''$''||NULL)
            ELSE (NODE_ID||''$''||SUBNODE_ID)
            END "NODE_KEY"
            FROM ODMRSYS.ODMR$WORKFLOW_RUN_NODES
          ) n, 
          (
            SELECT USER_NAME, JOB_NAME, PROJ_ID, WF_ID, NODE_ID, SUBNODE_ID, (NODE_ID||''$''||SUBNODE_ID) "NODE_KEY",
            log_subtype, log_task, log_type, log_duration, log_timestamp
            FROM ODMRSYS.ODMR$WF_LOG
          ) l
          WHERE n.WORKFLOW_JOB_ID = l.JOB_NAME (+) AND n.NODE_KEY = l.NODE_KEY (+)
        ) WHERE log_type IS NULL OR (log_subtype in (''START'',''END'') AND log_task in (''WORKFLOW'',''NODE'',''SUBNODE''))
      ),
      B AS (
        SELECT USER_NAME, WF_JOB_NAME, PROJ_ID, WF_ID, NODE_ID, SUBNODE_ID,
        MIN(NODE_START_TIME) NODE_START_TIME, MAX(NODE_RUN_TIME) NODE_RUN_TIME,
        sys.mvaggrawbitor(ENCODE_STATUS) "STATUS"
        FROM A
        group by USER_NAME, WF_JOB_NAME, PROJ_ID, WF_ID, NODE_ID, SUBNODE_ID
      )
      SELECT USER_NAME, WF_JOB_NAME, PROJ_ID, WF_ID, NODE_ID, SUBNODE_ID, NODE_START_TIME, NODE_RUN_TIME,
        CASE
            WHEN utl_raw.bit_or(STATUS, ''00000000'') = ''00000000'' THEN ''NOT_STARTED''
            WHEN utl_raw.bit_or(STATUS, ''10000001'') = ''10000001'' THEN ''RUNNING''
            WHEN utl_raw.bit_and(STATUS, ''00000100'') = ''00000100'' THEN ''FAILED''
            WHEN utl_raw.bit_or(STATUS, ''11000001'') = ''11000001'' THEN ''SUCCEEDED''
            WHEN utl_raw.bit_or(STATUS, ''11000011'') = ''11000011'' THEN ''SUCCEEDED''
        ELSE ''FAILED'' END "NODE_STATUS",
        CASE
            WHEN SUBNODE_ID IS NULL THEN NULL
            WHEN utl_raw.bit_or(STATUS, ''00000000'') = ''00000000'' THEN ''NOT_STARTED''
            WHEN utl_raw.bit_or(STATUS, ''10000001'') = ''10000001'' THEN ''RUNNING''
            WHEN utl_raw.bit_and(STATUS, ''00000100'') = ''00000100'' THEN ''FAILED''
            WHEN utl_raw.bit_or(STATUS, ''11000001'') = ''11000001'' THEN ''SUCCEEDED''
            WHEN utl_raw.bit_or(STATUS, ''11000011'') = ''11000011'' THEN ''SUCCEEDED''
        ELSE ''FAILED'' END "SUBNODE_STATUS"
      FROM B
      )';

    EXECUTE IMMEDIATE 'CREATE OR REPLACE VIEW ODMRSYS.ODMR_USER_WORKFLOW_ALL_POLL
      AS SELECT
        USER_NAME, 
        WF_JOB_NAME, 
        PROJ_ID, 
        WF_ID, 
        NODE_ID, 
        SUBNODE_ID, 
        NODE_START_TIME, 
        NODE_RUN_TIME,
        NODE_STATUS, 
        SUBNODE_STATUS
      FROM
        ODMRSYS.ODMR_ALL_WORKFLOW_ALL_POLL
      WHERE
        ODMR_ALL_WORKFLOW_ALL_POLL.USER_NAME = SYS_CONTEXT(''USERENV'', ''SESSION_USER'') OR ODMR_ALL_WORKFLOW_ALL_POLL.USER_NAME IS NULL';

    EXECUTE IMMEDIATE 'CREATE OR REPLACE PUBLIC SYNONYM ODMR_USER_WORKFLOW_ALL_POLL FOR ODMRSYS.ODMR_USER_WORKFLOW_ALL_POLL';

    EXECUTE IMMEDIATE 'GRANT SELECT ON ODMR_USER_WORKFLOW_ALL_POLL TO ODMRUSER';

    -- uptick the VERSION
    UPDATE ODMRSYS.ODMR$REPOSITORY_PROPERTIES SET PROPERTY_STR_VALUE = '&NEW_REPOSITORY_VERSION' WHERE PROPERTY_NAME = 'VERSION';
    COMMIT;  
    dbms_output.put_line('Repository version updated to ' || '&NEW_REPOSITORY_VERSION' || '.');
  ELSE
    dbms_output.put_line('Upgrade is not necessary.');
  END IF;
  EXCEPTION WHEN OTHERS THEN
   dbms_output.put_line('Failure during upgrade: '||DBMS_UTILITY.FORMAT_ERROR_STACK());
   RAISE;
END;
/

EXECUTE dbms_output.put_line('End repository upgrade from ' || '&OLD_REPOSITORY_VERSION' || ' to ' || '&NEW_REPOSITORY_VERSION' || '. ' || systimestamp);
