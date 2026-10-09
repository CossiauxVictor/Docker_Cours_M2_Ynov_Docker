package com.kennel.crud.logging;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestTemplate;

import java.time.Instant;

@Component
public class LogClient {

    private static final Logger LOGGER = LoggerFactory.getLogger(LogClient.class);

    private final RestTemplate restTemplate;
    private final String logsApiUrl;

    public LogClient(RestTemplate restTemplate, @Value("${logs.api.url}") String logsApiUrl) {
        this.restTemplate = restTemplate;
        this.logsApiUrl = logsApiUrl;
    }

    public void send(LogLevel level, String message, String source) {
        LogEntry entry = new LogEntry(message, source, Instant.now().toString(), level);
        try {
            restTemplate.postForObject(logsApiUrl, entry, LogEntry.class);
        } catch (Exception e) {
            LOGGER.warn("Unable to send log entry to logs-api: {}", e.getMessage());
        }
    }
}
