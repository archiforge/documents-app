package com.docdeck.officeconversion;

import com.docdeck.officeconversion.config.OfficeConversionProperties;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.EnableConfigurationProperties;

@SpringBootApplication
@EnableConfigurationProperties(OfficeConversionProperties.class)
public class OfficeConversionApplication {
    public static void main(String[] args) {
        SpringApplication.run(OfficeConversionApplication.class, args);
    }
}
