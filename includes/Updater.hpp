/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   Updater.hpp                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: agarcia2 <agarcia2@student.42barcelona.co>                           */
/*                                                                            */
/* ************************************************************************** */

#pragma once

#import <Foundation/Foundation.h>
#include <string>

class Updater {
public:
    static Updater& getInstance() {
        static Updater instance;
        return instance;
    }

    void setUpdateConfig(const std::string& manifestUrl, const std::string& currentVersion);
    void checkForUpdates();

private:
    Updater() = default;
    
    std::string m_manifestUrl;
    std::string m_currentVersion;
    
    bool isTrustedURL(NSURL* url);
    void downloadFile(NSURL* url, void (^completion)(NSString* downloadedPath, NSError* error));
    std::string sha256OfFile(NSString* path);
    bool applyUpdate(const std::string& newDylibPath);
    bool isVersionNewer(const std::string& remoteVersion, const std::string& localVersion);
};
