/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   iOSSimulatorContext.hpp                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: agarcia2 <agarcia2@student.42barcelona.co  +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/22 10:53:07 by agarcia2          #+#    #+#             */
/*   Updated: 2026/10/22 10:53:13 by agarcia2         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

#pragma once
#include <string>
#include <cerrno>
#include <cstring>
#include <sys/stat.h>
#include <unistd.h>
#include "Logger.hpp"

class iOSSimulatorContext {
public:
    static iOSSimulatorContext& getInstance() {
        static iOSSimulatorContext instance;
        return instance;
    }

    bool emulateiOSDirectories(const std::string& baseContainerPath) {
        LOG_I("iOSSim", "Replicant estructura de contenidor a: %s", baseContainerPath.c_str());

        std::string documentsPath = baseContainerPath + "/Documents";
        std::string libraryPath = baseContainerPath + "/Library";
        std::string cachePath = libraryPath + "/Caches";

        bool ok = true;
        ok &= createDirectory(documentsPath);
        ok &= createDirectory(libraryPath);
        ok &= createDirectory(cachePath);

        if (ok)
            LOG_I("iOSSim", "Estructura de directoris replicada amb exit.");
        else
            LOG_E("iOSSim", "Algun directori no s'ha pogut crear.");
        return ok;
    }

private:
    iOSSimulatorContext() = default;

    bool createDirectory(const std::string& path) {
        struct stat st = {};
        if (stat(path.c_str(), &st) == 0)
            return S_ISDIR(st.st_mode);
        if (mkdir(path.c_str(), 0755) == 0) {
            LOG_D("iOSSim", "Creat directori: %s", path.c_str());
            return true;
        }
        LOG_E("iOSSim", "mkdir fallat (%s): %s", path.c_str(), strerror(errno));
        return false;
    }
};
