package com.kennel.logs.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.kennel.logs.model.LogEntry;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.List;

@Service
public class LogStorageService {

    private final Path logFile;
    private final ObjectMapper objectMapper = new ObjectMapper();

    public LogStorageService(@Value("${logs.storage.path:/data/logs.jsonl}") String storagePath) throws IOException {
        this.logFile = Paths.get(storagePath);
        Path parent = logFile.getParent();
        if (parent != null) {
            Files.createDirectories(parent);
        }
        if (!Files.exists(logFile)) {
            Files.createFile(logFile);
        }
    }

    public synchronized LogEntry append(LogEntry entry) {
        try {
            String line = objectMapper.writeValueAsString(entry);
            Files.writeString(logFile, line + System.lineSeparator(),
                    StandardOpenOption.CREATE, StandardOpenOption.APPEND);
            return entry;
        } catch (IOException e) {
            throw new RuntimeException("Unable to write log entry", e);
        }
    }

    public synchronized List<LogEntry> findAll() {
        List<LogEntry> entries = new ArrayList<>();
        try {
            for (String line : Files.readAllLines(logFile)) {
                if (!line.isBlank()) {
                    entries.add(objectMapper.readValue(line, LogEntry.class));
                }
            }
        } catch (IOException e) {
            throw new RuntimeException("Unable to read log entries", e);
        }
        return entries;
    }
}
