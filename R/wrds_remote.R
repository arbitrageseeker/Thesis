library(RPostgres)
wrds <- dbConnect(Postgres(),
                  host='wrds-pgdata.wharton.upenn.edu',
                  port=9737,
                  dbname='wrds',
                  sslmode='require',
                  user=rstudioapi::askForPassword("Database username"),
                  password=rstudioapi::askForPassword("Database password"))

res <- dbSendQuery(wrds, "select distinct table_schema
                   from information_schema.tables
                   where table_type ='VIEW'
                   or table_type = 'FOREIGN TABLE'
                   order by table_schema")
data_all <- dbFetch(res, n=-1)

dbClearResult(res)
data_all


res <- dbSendQuery(wrds, "select distinct table_name
                   from information_schema.columns
                   where table_schema='tfn'
                   order by table_name")
tfn <- dbFetch(res, n=-1)
dbClearResult(res)
tfn

res <- dbSendQuery(wrds, "select column_name
                   from information_schema.columns
                   where table_schema='tfn'
                   and table_name='s34'
                   order by column_name")
data <- dbFetch(res, n=-1)
dbClearResult(res)
data

res <- dbSendQuery(wrds, "select *
                          from tfn.s34
                          where fdate between '1996-01-01'
                          and '2017-12-31'")
data <- dbFetch(res, n=-1)
dbClearResult(res)
library(tidyverse)
data <- as.tbl(data)

as_tb
