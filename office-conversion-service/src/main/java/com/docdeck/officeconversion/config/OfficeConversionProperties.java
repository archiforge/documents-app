package com.docdeck.officeconversion.config;

import java.time.Duration;
import org.springframework.boot.context.properties.ConfigurationProperties;

/** Runtime limits and isolation requirements for one local conversion service. */
@ConfigurationProperties(prefix = "office.conversion")
public class OfficeConversionProperties {
    private String libreOfficeExecutable = "soffice";
    private String sandboxExecutable = "";
    private String sandboxProfileTemplate = "";
    private String resourceLauncherExecutable = "";
    private String workspaceRoot = "";
    private String runtimeReadRoot = "";
    private String authToken = "";
    private long maxInputBytes = 50L * 1024L * 1024L;
    private long maxOutputBytes = 100L * 1024L * 1024L;
    private Duration timeout = Duration.ofSeconds(120);
    private int maxConcurrentJobs = 2;
    private int maxZipEntries = 10_000;
    private long maxUncompressedArchiveBytes = 100L * 1024L * 1024L;
    private long maxProcessMemoryBytes = 1024L * 1024L * 1024L;

    public String getLibreOfficeExecutable() {
        return libreOfficeExecutable;
    }

    public void setLibreOfficeExecutable(String libreOfficeExecutable) {
        this.libreOfficeExecutable = libreOfficeExecutable;
    }

    public String getSandboxExecutable() {
        return sandboxExecutable;
    }

    public void setSandboxExecutable(String sandboxExecutable) {
        this.sandboxExecutable = sandboxExecutable;
    }

    public String getSandboxProfileTemplate() {
        return sandboxProfileTemplate;
    }

    public void setSandboxProfileTemplate(String sandboxProfileTemplate) {
        this.sandboxProfileTemplate = sandboxProfileTemplate;
    }

    public String getResourceLauncherExecutable() {
        return resourceLauncherExecutable;
    }

    public void setResourceLauncherExecutable(String resourceLauncherExecutable) {
        this.resourceLauncherExecutable = resourceLauncherExecutable;
    }

    public String getWorkspaceRoot() {
        return workspaceRoot;
    }

    public void setWorkspaceRoot(String workspaceRoot) {
        this.workspaceRoot = workspaceRoot;
    }

    public String getRuntimeReadRoot() {
        return runtimeReadRoot;
    }

    public void setRuntimeReadRoot(String runtimeReadRoot) {
        this.runtimeReadRoot = runtimeReadRoot;
    }

    public String getAuthToken() {
        return authToken;
    }

    public void setAuthToken(String authToken) {
        this.authToken = authToken;
    }

    public long getMaxInputBytes() {
        return maxInputBytes;
    }

    public void setMaxInputBytes(long maxInputBytes) {
        this.maxInputBytes = maxInputBytes;
    }

    public long getMaxOutputBytes() {
        return maxOutputBytes;
    }

    public void setMaxOutputBytes(long maxOutputBytes) {
        this.maxOutputBytes = maxOutputBytes;
    }

    public Duration getTimeout() {
        return timeout;
    }

    public void setTimeout(Duration timeout) {
        this.timeout = timeout;
    }

    public int getMaxConcurrentJobs() {
        return maxConcurrentJobs;
    }

    public void setMaxConcurrentJobs(int maxConcurrentJobs) {
        this.maxConcurrentJobs = maxConcurrentJobs;
    }

    public int getMaxZipEntries() {
        return maxZipEntries;
    }

    public void setMaxZipEntries(int maxZipEntries) {
        this.maxZipEntries = maxZipEntries;
    }

    public long getMaxUncompressedArchiveBytes() {
        return maxUncompressedArchiveBytes;
    }

    public void setMaxUncompressedArchiveBytes(long maxUncompressedArchiveBytes) {
        this.maxUncompressedArchiveBytes = maxUncompressedArchiveBytes;
    }

    public long getMaxProcessMemoryBytes() {
        return maxProcessMemoryBytes;
    }

    public void setMaxProcessMemoryBytes(long maxProcessMemoryBytes) {
        this.maxProcessMemoryBytes = maxProcessMemoryBytes;
    }
}
