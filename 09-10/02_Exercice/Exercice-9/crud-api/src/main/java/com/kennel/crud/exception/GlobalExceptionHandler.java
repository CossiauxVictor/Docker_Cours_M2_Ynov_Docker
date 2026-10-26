package com.kennel.crud.exception;

import com.kennel.crud.logging.LogClient;
import com.kennel.crud.logging.LogLevel;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

@RestControllerAdvice
public class GlobalExceptionHandler {

    private final LogClient logClient;

    public GlobalExceptionHandler(LogClient logClient) {
        this.logClient = logClient;
    }

    @ExceptionHandler(ResourceNotFoundException.class)
    public ResponseEntity<String> handleNotFound(ResourceNotFoundException ex, HttpServletRequest request) {
        String source = "[CrudAPI] " + request.getMethod() + " " + request.getRequestURI();
        logClient.send(LogLevel.ERR, ex.getMessage(), source);
        return ResponseEntity.status(HttpStatus.NOT_FOUND).body(ex.getMessage());
    }
}
