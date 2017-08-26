
-- Function used to create roles at startup when we don't yet know if the database is new
-- or if it's being restored from backup. This will update the passwords for existing users.
CREATE OR REPLACE FUNCTION create_or_update_role_with_password(rolename TEXT, rolepassword TEXT) RETURNS VOID AS
$$
BEGIN
  IF NOT EXISTS (SELECT * FROM pg_roles WHERE rolname = rolename) THEN
    EXECUTE 'CREATE USER "' || rolename || '" WITH PASSWORD ''' || rolepassword || '''';
    RAISE NOTICE 'CREATE USER "%" WITH PASSWORD ''%''', rolename, rolepassword;
  ELSE
    EXECUTE 'ALTER USER "' || rolename || '" WITH PASSWORD ''' || rolepassword || '''';
    RAISE NOTICE 'ALTER USER "%" WITH PASSWORD ''%''', rolename, rolepassword;
  END IF;
END;
$$
LANGUAGE plpgsql;

-- Function used to parse CSV list of strings
CREATE OR REPLACE FUNCTION create_or_update_credentials(user_list text[], password_list text[]) RETURNS VOID AS
$$
BEGIN
  FOR i IN 1 .. array_upper(user_list, 1)
  LOOP
    PERFORM create_or_update_role_with_password(user_list[i], password_list[i]);
  END LOOP;
END;
$$
LANGUAGE plpgsql;

-- enable required extensions
create extension pgcrypto;
create extension pg_stat_statements;
create extension pgaudit;

-- change passwords of admin users
SELECT create_or_update_role_with_password('postgres', 'PG_ROOT_PASSWORD');
SELECT create_or_update_role_with_password('PG_MASTER_USER', 'PG_MASTER_PASSWORD');
ALTER USER "PG_MASTER_USER" WITH REPLICATION;

create database PG_DATABASE;

-- create custom users specified in csv and apply privileges
DO $$
DECLARE
  user_list text[] := regexp_split_to_array('PG_USER', ',');
  password_list text[] := regexp_split_to_array('PG_PASSWORD', ',');
  appadmin text := user_list[1];
  appuser text := user_list[2];
BEGIN
  RAISE NOTICE 'APPADMIN %', appadmin;
  RAISE NOTICE 'APPUSER %', appuser;

  PERFORM create_or_update_credentials(user_list, password_list);

  EXECUTE 'alter database PG_DATABASE owner to ' || quote_ident(appadmin);

  EXECUTE 'grant all privileges on database PG_DATABASE to ' || quote_ident(appadmin);
  EXECUTE 'grant all on all tables in schema public to ' || quote_ident(appadmin);

  EXECUTE 'grant all privileges on database PG_DATABASE to ' || quote_ident(appuser);
  EXECUTE 'grant all on all tables in schema public to ' || quote_ident(appuser);

END
$$;

-- This function is useful for getting a loose assessment of what's in the database
-- so that we can compare and validate against another copy of the database
CREATE TYPE table_count AS (table_name TEXT, num_rows INTEGER);
CREATE OR REPLACE FUNCTION count_em_all () RETURNS SETOF table_count
AS '
DECLARE
  the_count RECORD;
  t_name RECORD;
  r table_count%ROWTYPE;
BEGIN
  FOR t_name IN
  SELECT c.relname
  FROM
    pg_catalog.pg_class c
    LEFT JOIN
    pg_namespace n
      ON
        n.oid = c.relnamespace
  WHERE
    c.relkind = ''r''
    AND
    n.nspname = ''public''
  ORDER BY 1
  LOOP
    BEGIN
      -- The next 3 lines are a hack according to the author.
      FOR the_count IN EXECUTE ''SELECT COUNT(*) AS "count" FROM '' || t_name.relname
      LOOP
      END LOOP;
      r.table_name := t_name.relname;
      r.num_rows := the_count.count;
      RETURN NEXT r;
      EXCEPTION
      WHEN others THEN
        CONTINUE;
    END;
  END LOOP;
  RETURN;
END;
' LANGUAGE plpgsql;
COMMENT ON FUNCTION count_em_all () IS 'Spits out all tables in the public schema and the exact row counts for each.';

