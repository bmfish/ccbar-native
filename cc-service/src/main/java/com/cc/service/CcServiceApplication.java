package com.cc.service;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableScheduling;

@EnableScheduling
@SpringBootApplication
public class CcServiceApplication {

    public static void main(String[] args) {
        SpringApplication.run(CcServiceApplication.class, args);
    }
}
