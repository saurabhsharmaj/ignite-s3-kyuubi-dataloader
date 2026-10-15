# Ignite -> Parquet -> MinIO (S3) -> Hive

## Prerequisites
- JDK 17, IntelliJ (Maven is bundled), Docker Desktop
- Ignite running locally with the thin-client port 10800 open

## 1. Start MinIO + Hive
1. Download the two jars into `docker/jars` (see `docker/jars/README.md`).
2. `cd docker && docker compose up -d`
3. MinIO console: http://localhost:9001 (minioadmin / minioadmin). Bucket `ignite-export` is created automatically.

## 2. Run the Spring Boot app
- Open the project folder in IntelliJ (File > Open > pom.xml > Open as Project).
- Use the shared run config **IgniteExportApplication** (it already has the JVM flags Ignite needs on Java 17).
  If you create your own run config, copy the VM options from `.run/IgniteExportApplication.run.xml`.
- Or from a terminal: `mvn spring-boot:run`

## 3. Seed and export
```
curl -X POST "http://localhost:8080/seed?rows=1000"     # optional: creates PERSON table in Ignite + sample rows
curl -X POST  http://localhost:8080/export              # writes Parquet to s3://ignite-export/person/
```
(PowerShell: use `curl.exe -X POST ...` or `Invoke-RestMethod -Method Post -Uri ...`)

## 4. Check in WinSCP
Protocol: Amazon S3, Host: localhost, Port: 9000, Access key/secret: minioadmin.
If TLS errors appear, disable encryption or use `s3plain://minioadmin:minioadmin@localhost:9000/`.

## 5. Query in Hive
```
docker exec -it hive beeline -u "jdbc:hive2://localhost:10000/"
```
Then run the statements in `docker/hive-create-table.sql`.

## Using your own table
1. Edit `export.sql` in `application.yml`.
2. Edit `SCHEMA` and `toRecord()` in `ExportService.java`.
3. Edit the Hive DDL to match column names/types.
