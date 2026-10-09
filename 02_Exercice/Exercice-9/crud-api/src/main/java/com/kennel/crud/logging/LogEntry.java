package com.kennel.crud.logging;

public class LogEntry {

    private String message;
    private String source;
    private String timestamp;
    private LogLevel level;

    public LogEntry() {
    }

    public LogEntry(String message, String source, String timestamp, LogLevel level) {
        this.message = message;
        this.source = source;
        this.timestamp = timestamp;
        this.level = level;
    }

    public String getMessage() {
        return message;
    }

    public void setMessage(String message) {
        this.message = message;
    }

    public String getSource() {
        return source;
    }

    public void setSource(String source) {
        this.source = source;
    }

    public String getTimestamp() {
        return timestamp;
    }

    public void setTimestamp(String timestamp) {
        this.timestamp = timestamp;
    }

    public LogLevel getLevel() {
        return level;
    }

    public void setLevel(LogLevel level) {
        this.level = level;
    }
}
