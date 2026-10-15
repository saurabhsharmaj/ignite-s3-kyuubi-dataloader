
package com.example.igniteexport;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@RestController
@RequestMapping("/")
public class ExportController {

    private final ExportService service;

    public ExportController(ExportService service) {
        this.service = service;
    }

    /**
     * Creates the PUBLIC.PERSON table in Ignite 3 if missing
     * and inserts the requested sample rows.
     *
     * Example: GET http://localhost:8080/seed?rows=10
     */
    @GetMapping("/seed")
    public Map<String, Object> seed(
            @RequestParam(defaultValue = "1000") int rows) {
        return service.seed(rows);
    }

    /**
     * Executes the configured export SQL, writes Parquet files,
     * and uploads them to the configured S3/MinIO bucket.
     *
     * Example: GET http://localhost:8080/export
     */
    @GetMapping("/export")
    public Map<String, Object> export() throws Exception {
        return service.export();
    }
}