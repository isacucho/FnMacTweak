/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   Logger.hpp                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: agarcia2 <agarcia2@student.42barcelona.co  +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/22 10:52:50 by agarcia2          #+#    #+#             */
/*   Updated: 2026/10/22 10:52:59 by agarcia2         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

#pragma once
#include <iostream>
#include <string>
#include <chrono>
#include <iomanip>
#include <mutex>
#include <cstdio>
#include <ctime>
#import <Foundation/Foundation.h>
#include "fndiag/log.hpp"

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
    Logger() = default;
    std::mutex m_mutex;

    void printLog(LogLevel level, const std::string& tag, const char* format) {
        emit(level, tag, format);
    }

    template<typename... Args>
    void printLog(LogLevel level, const std::string& tag, const char* format, Args... args) {
        char finalBuffer[2048];
        std::snprintf(finalBuffer, sizeof(finalBuffer), format, args...);
        emit(level, tag, finalBuffer);
    }

    void emit(LogLevel level, const std::string& tag, const char* msg) {
        std::lock_guard<std::mutex> lock(m_mutex);

        // os_log + Documents/FnDiag.log (si log_init abrio el fichero)
        fndiag::log_line("[%s] %s", tag.c_str(), msg);
        writeLogHeader(level, tag);
        std::cout << msg << std::endl;
    }

    void writeLogHeader(LogLevel level, const std::string& tag) {
        auto now = std::chrono::system_clock::now();
        std::time_t time_val = std::chrono::system_clock::to_time_t(now);
        std::tm tm_buf;
        localtime_r(&time_val, &tm_buf);
        std::cout << "[" << std::put_time(&tm_buf, "%H:%M:%S") << "] ";
        std::cout << "[" << getLevelString(level) << "] [" << tag << "] ";
    }

    const char* getLevelString(LogLevel level) {
        switch (level) {
            case LogLevel::DEBUG:   return "DEBUG";
            case LogLevel::INFO:    return "INFO";
            case LogLevel::WARNING: return "WARN";
            case LogLevel::ERROR:   return "ERROR";
        }
        return "UNKNOWN";
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
