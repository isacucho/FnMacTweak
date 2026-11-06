#pragma once
#include <chrono>
#include <cstdio>
#include <ctime>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <string>
#include <os/log.h>

// Subsistema unificado. Visible en Console.app filtrando por "com.alexgrdev.fnmaccompat".
#define FNCOMPAT_SUBSYSTEM "com.alexgrdev.fnmaccompat"

enum class LogLevel { DEBUG, INFO, WARNING, ERROR };

class Logger {
public:
    static Logger& getInstance() {
        static Logger instance;
        return instance;
    }

    void log(LogLevel level, const std::string& tag, const std::string& message) {
        printLog(level, tag, "%s", message.c_str());
    }

    template<typename... Args>
    void log(LogLevel level, const std::string& tag, const char* format, Args... args) {
        printLog(level, tag, format, args...);
    }

private:
    Logger() : m_log(os_log_create(FNCOMPAT_SUBSYSTEM, "main")) {}
    std::mutex m_mutex;
    os_log_t m_log;

    template<typename... Args>
    void printLog(LogLevel level, const std::string& tag, const char* format, Args... args) {
        char buf[2048];
        std::snprintf(buf, sizeof(buf), format, args...);
        emit(level, tag, buf);
    }

    void printLog(LogLevel level, const std::string& tag, const char* format) {
        emit(level, tag, format);
    }

    void emit(LogLevel level, const std::string& tag, const char* msg) {
        std::lock_guard<std::mutex> lock(m_mutex);
        os_log_with_type(m_log, toOsType(level), "[%{public}s] %{public}s", tag.c_str(), msg);
        writeHeader(level, tag);
        std::cout << msg << std::endl;
    }

    os_log_type_t toOsType(LogLevel level) {
        switch (level) {
            case LogLevel::DEBUG:   return OS_LOG_TYPE_DEBUG;
            case LogLevel::INFO:    return OS_LOG_TYPE_INFO;
            case LogLevel::WARNING: return OS_LOG_TYPE_DEFAULT;
            case LogLevel::ERROR:   return OS_LOG_TYPE_ERROR;
        }
        return OS_LOG_TYPE_DEFAULT;
    }

    void writeHeader(LogLevel level, const std::string& tag) {
        auto now = std::chrono::system_clock::now();
        std::time_t t = std::chrono::system_clock::to_time_t(now);
        std::tm tm_buf;
        localtime_r(&t, &tm_buf);
        std::cout << "[" << std::put_time(&tm_buf, "%H:%M:%S") << "] ";
        std::cout << "[" << levelStr(level) << "] [" << tag << "] ";
    }

    const char* levelStr(LogLevel level) {
        switch (level) {
            case LogLevel::DEBUG:   return "DEBUG";
            case LogLevel::INFO:    return "INFO";
            case LogLevel::WARNING: return "WARN";
            case LogLevel::ERROR:   return "ERROR";
        }
        return "?";
    }
};

#ifdef PRODUCTION
    #define LOG_D(tag, fmt, ...) do {} while(0)
    #define LOG_I(tag, fmt, ...) do {} while(0)
    #define LOG_W(tag, fmt, ...) Logger::getInstance().log(LogLevel::WARNING, tag, fmt, ##__VA_ARGS__)
    #define LOG_E(tag, fmt, ...) Logger::getInstance().log(LogLevel::ERROR,   tag, fmt, ##__VA_ARGS__)
#else
    #define LOG_D(tag, fmt, ...) Logger::getInstance().log(LogLevel::DEBUG,   tag, fmt, ##__VA_ARGS__)
    #define LOG_I(tag, fmt, ...) Logger::getInstance().log(LogLevel::INFO,    tag, fmt, ##__VA_ARGS__)
    #define LOG_W(tag, fmt, ...) Logger::getInstance().log(LogLevel::WARNING, tag, fmt, ##__VA_ARGS__)
    #define LOG_E(tag, fmt, ...) Logger::getInstance().log(LogLevel::ERROR,   tag, fmt, ##__VA_ARGS__)
#endif
