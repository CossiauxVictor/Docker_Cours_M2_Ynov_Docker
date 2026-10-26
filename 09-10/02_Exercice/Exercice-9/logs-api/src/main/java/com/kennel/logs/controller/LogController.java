package com.kennel.logs.controller;

import com.kennel.logs.model.LogEntry;
import com.kennel.logs.service.LogStorageService;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/v1/logs")
public class LogController {

    private final LogStorageService logStorageService;

    public LogController(LogStorageService logStorageService) {
        this.logStorageService = logStorageService;
    }

    @GetMapping
    public List<LogEntry> getAllLogs() {
        return logStorageService.findAll();
    }

    @PostMapping
    public LogEntry createLog(@RequestBody LogEntry logEntry) {
        return logStorageService.append(logEntry);
    }
}
