
package com.example.igniteexport;

import org.apache.avro.Schema;
import org.apache.avro.generic.GenericData;
import org.apache.avro.generic.GenericRecord;
import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.Path;
import org.apache.parquet.avro.AvroParquetWriter;
import org.apache.parquet.hadoop.ParquetFileWriter;
import org.apache.parquet.hadoop.ParquetWriter;
import org.apache.parquet.hadoop.metadata.CompressionCodecName;
import org.apache.parquet.hadoop.util.HadoopOutputFile;

import org.apache.ignite.client.IgniteClient;
import org.apache.ignite.sql.ResultSet;
import org.apache.ignite.sql.SqlRow;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.S3Configuration;
import software.amazon.awssdk.services.s3.model.DeleteObjectsRequest;
import software.amazon.awssdk.services.s3.model.ObjectIdentifier;
import software.amazon.awssdk.services.s3.model.PutObjectRequest;
import software.amazon.awssdk.services.s3.model.ListObjectsV2Request;
import software.amazon.awssdk.services.s3.model.ListObjectsV2Response;
import software.amazon.awssdk.services.s3.model.S3Object;

import java.io.IOException;
import java.math.BigDecimal;
import java.net.URI;
import java.nio.file.Files;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

@Service
public class ExportService {

    @Value("${ignite.address:127.0.0.1:10800}")
    private String igniteAddress;

    @Value("${s3.endpoint:http://localhost:8333}")
    private String s3Endpoint;

    @Value("${s3.access-key:admin}")
    private String s3AccessKey;

    @Value("${s3.secret-key:admin12345}")
    private String s3SecretKey;

    @Value("${s3.bucket}")
    private String s3Bucket;

    @Value("${s3.prefix:person/}")
    private String s3Prefix;

    @Value("${s3.clean-before-export:false}")
    private boolean cleanBeforeExport;

    @Value("${export.sql}")
    private String exportSql;

    @Value("${export.rows-per-file:100000}")
    private int rowsPerFile;

    private static final Schema SCHEMA =
            new Schema.Parser().parse("""
            {
              "type": "record",
              "name": "PersonExport",
              "fields": [
                {"name": "ID", "type": "long"},
                {"name": "NAME", "type": ["null", "string"], "default": null},
                {"name": "AMOUNT", "type": ["null", "double"], "default": null}
              ]
            }
            """);
    /**
     * Creates a sample table and inserts test records.
     * This endpoint populates PUBLIC.PERSON, not PUBLIC.USERS.
     */
    public Map<String, Object> seed(int rows) {
        if (rows < 0) {
            throw new IllegalArgumentException("rows must be zero or greater");
        }

        try (IgniteClient client = connect()) {
            client.sql().execute(null, """
                    CREATE TABLE IF NOT EXISTS PUBLIC.PERSON (
                        ID BIGINT PRIMARY KEY,
                        NAME VARCHAR,
                        AMOUNT DOUBLE
                    )
                    """);

            for (int i = 1; i <= rows; i++) {
                client.sql().execute(
                        null,
                        "INSERT INTO PUBLIC.PERSON (ID, NAME, AMOUNT) VALUES (?, ?, ?)",
                        (long) i,
                        "Person-" + i,
                        i * 10.5
                );
            }

            Map<String, Object> response = new LinkedHashMap<>();
            response.put("status", "success");
            response.put("table", "PUBLIC.PERSON");
            response.put("requestedRows", rows);
            return response;
        }
    }

    /**
     * Exports the configured SQL query to one or more Parquet files
     * and uploads them to the configured S3 bucket/prefix.
     */
    public Map<String, Object> export() throws Exception {
        if (rowsPerFile < 1) {
            throw new IllegalArgumentException(
                    "export.rows-per-file must be greater than zero");
        }

        List<String> uploadedFiles = new ArrayList<>();
        long totalRows = 0;
        int fileNumber = 0;
        long rowsInCurrentFile = 0;

        java.nio.file.Path tempFile = null;
        ParquetWriter<GenericRecord> writer = null;

        try (IgniteClient client = connect();
             S3Client s3 = buildS3()) {

            if (cleanBeforeExport) {
                deletePrefix(s3);
            }

            try (ResultSet<SqlRow> resultSet =
                         client.sql().execute(null, exportSql)) {

                for (ResultSet<SqlRow> it = resultSet; it.hasNext(); ) {
                    SqlRow row = it.next();
                    if (writer == null || rowsInCurrentFile >= rowsPerFile) {
                        if (writer != null) {
                            writer.close();
                            writer = null;

                            String key = uploadFile(
                                    s3, tempFile, fileNumber);
                            uploadedFiles.add(key);

                            Files.deleteIfExists(tempFile);
                            tempFile = null;
                        }

                        fileNumber++;
                        rowsInCurrentFile = 0;

                        tempFile = Files.createTempFile(
                                "ignite-export-", ".parquet");

                        writer = createWriter(tempFile);
                    }

                    GenericRecord record = toRecord(row);
                    writer.write(record);

                    rowsInCurrentFile++;
                    totalRows++;
                }
            }

            if (writer != null) {
                writer.close();
                writer = null;

                String key = uploadFile(s3, tempFile, fileNumber);
                uploadedFiles.add(key);

                Files.deleteIfExists(tempFile);
                tempFile = null;
            }

            Map<String, Object> response = new LinkedHashMap<>();
            response.put("status", "success");
            response.put("totalRows", totalRows);
            response.put("filesCreated", uploadedFiles.size());
            response.put("bucket", s3Bucket);
            response.put("uploadedFiles", uploadedFiles);

            return response;

        } finally {
            if (writer != null) {
                try {
                    writer.close();
                } catch (IOException ignored) {
                    // Preserve the original exception, if any.
                }
            }

            if (tempFile != null) {
                Files.deleteIfExists(tempFile);
            }
        }
    }

    private IgniteClient connect() {
        String[] addresses = igniteAddress.split("\\s*,\\s*");

        return IgniteClient.builder()
                .addresses(addresses)
                .build();
    }

    private ParquetWriter<GenericRecord> createWriter(
            java.nio.file.Path tempFile) throws IOException {

        Path hadoopPath = new Path(tempFile.toUri());

        return AvroParquetWriter.<GenericRecord>builder(
                        HadoopOutputFile.fromPath(
                                hadoopPath,
                                new Configuration()))
                .withSchema(SCHEMA)
                .withCompressionCodec(CompressionCodecName.SNAPPY)
                .withWriteMode(ParquetFileWriter.Mode.OVERWRITE)
                .build();
    }


    private GenericRecord toRecord(SqlRow row) {
        GenericRecord record = new GenericData.Record(SCHEMA);

        Object id = row.value(0);
        if (!(id instanceof Number number)) {
            throw new IllegalArgumentException(
                    "Expected numeric ID, received: " + id);
        }

        record.put("ID", number.longValue());
        record.put("NAME", asString(row.value(1)));

        Object amount = row.value(2);
        record.put(
                "AMOUNT",
                amount == null ? null : ((Number) amount).doubleValue());

        return record;
    }


    private String asString(Object value) {
        if (value == null) {
            return null;
        }

        if (value instanceof Instant instant) {
            return instant.toString();
        }

        if (value instanceof BigDecimal decimal) {
            return decimal.toPlainString();
        }

        return value.toString();
    }

    private String uploadFile(
            S3Client s3,
            java.nio.file.Path file,
            int fileNumber) {

        String fileName = String.format(
                "users-%s-%05d.parquet",
                System.currentTimeMillis(),
                fileNumber);

        String key = normalizePrefix(s3Prefix) + fileName;

        s3.putObject(
                PutObjectRequest.builder()
                        .bucket(s3Bucket)
                        .key(key)
                        .contentType("application/vnd.apache.parquet")
                        .build(),
                RequestBody.fromFile(file));

        return "s3://" + s3Bucket + "/" + key;
    }

    private void deletePrefix(S3Client s3) {
        String prefix = normalizePrefix(s3Prefix);
        String continuationToken = null;

        do {
            ListObjectsV2Request.Builder listBuilder =
                    ListObjectsV2Request.builder()
                            .bucket(s3Bucket)
                            .prefix(prefix);

            if (continuationToken != null) {
                listBuilder.continuationToken(continuationToken);
            }

            ListObjectsV2Response response =
                    s3.listObjectsV2(listBuilder.build());

            List<ObjectIdentifier> objects = response.contents()
                    .stream()
                    .map(S3Object::key)
                    .map(key -> ObjectIdentifier.builder().key(key).build())
                    .toList();

            if (!objects.isEmpty()) {
                s3.deleteObjects(
                        DeleteObjectsRequest.builder()
                                .bucket(s3Bucket)
                                .delete(delete -> delete.objects(objects))
                                .build());
            }

            continuationToken = response.nextContinuationToken();

        } while (continuationToken != null);
    }

    private S3Client buildS3() {
        return S3Client.builder()
                .endpointOverride(URI.create(s3Endpoint))
                .region(Region.US_EAST_1)
                .credentialsProvider(
                        StaticCredentialsProvider.create(
                                AwsBasicCredentials.create(
                                        s3AccessKey,
                                        s3SecretKey)))
                .serviceConfiguration(
                        S3Configuration.builder()
                                .pathStyleAccessEnabled(true)
                                .build())
                .build();
    }

    private String normalizePrefix(String prefix) {
        if (prefix == null || prefix.isBlank()) {
            return "";
        }

        String normalized = prefix.replace('\\', '/');

        while (normalized.startsWith("/")) {
            normalized = normalized.substring(1);
        }

        return normalized.endsWith("/")
                ? normalized
                : normalized + "/";
    }

}
