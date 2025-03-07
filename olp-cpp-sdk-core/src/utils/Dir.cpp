/*
 * Copyright (C) 2019-2023 HERE Europe B.V.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * SPDX-License-Identifier: Apache-2.0
 * License-Filename: LICENSE
 */

#include "olp/core/utils/Dir.h"

#include <cstring>
#if defined(_WIN32) && !defined(__MINGW32__)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <olp/core/utils/WarningWorkarounds.h>
#include <strsafe.h>
#include <tchar.h>
#include <windows.h>
#include <vector>
#else
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <queue>
#include <string>
#endif

#if defined(_WIN32) && !defined(__MINGW32__)
#define G_COUNTOF(array) (sizeof(array) / sizeof(array[0]))
#endif

namespace olp {
namespace utils {

namespace {
#if defined(_WIN32) && !defined(__MINGW32__)
#ifdef _UNICODE
std::wstring ConvertStringToWideString(const std::string& str) {
  int size_needed =
      MultiByteToWideChar(CP_ACP, 0, &str[0], str.size(), NULL, 0);
  std::wstring wstr_path(size_needed, 0);
  MultiByteToWideChar(CP_ACP, 0, &str[0], str.size(), &wstr_path[0],
                      size_needed);
  return wstr_path;
}
#endif  // _UNICODE
#endif  // _WIN32 && _MINGW32

#if !defined(_WIN32) || defined(__MINGW32__)
int remove_dir_callback(const char* file, const struct stat* /*stat*/, int flag,
                        struct FTW* /*buf*/) {
  int rc = 0;

  // take the advantage of the passed info here about file type and try to
  // optimize: remove() on QNX issues extra lstat() call, avoid it

  switch (flag) {
    case FTW_F:
    case FTW_SL:
    case FTW_SLN:
      rc = ::unlink(file);
      break;

    case FTW_D:
    case FTW_DP:
    case FTW_DNR:
      rc = ::rmdir(file);
      break;

    default:
      rc = ::remove(file);
      break;
  }
  return rc;
}

static bool mkdir_all(const char* dirname, int mode) {
  const char* ptr = dirname;
  if (*ptr == '\0') {
    return true;
  }

  const char* end = ptr;
  if (*end == '/') {
    ++end;
  }

  while (*end != '\0') {
    while (*end != '\0' && *end != '/') {
      ++end;
    }

    std::string subdir(ptr, end - ptr);

#if defined(__MINGW32__)
    int rc = mkdir(subdir.c_str());
#else
    int rc = mkdir(subdir.c_str(), mode);
#endif
    if (rc != 0 && errno != EEXIST) {
      return false;
    }

    if (*end == '\0') {
      break;
    }

    ++end;
  }

  return true;
}
#endif  // ifndef _WIN32

#if defined(_WIN32) && !defined(__MINGW32__)
void Tokenize(const std::string& path, const std::string& delimiters,
              std::vector<std::string>& result) {
  std::string sub_path = path;
  while (1) {
    size_t position = sub_path.find(delimiters);
    if (position != std::string::npos) {
      result.push_back(sub_path.substr(0, position));
      sub_path =
          sub_path.substr(position + delimiters.length(), std::string::npos);
    } else {
      result.push_back(sub_path);
      break;
    }
  }
}

bool DeleteDirectory(const TCHAR* utfdirPath) {
  HANDLE hFind;  // file handle
  WIN32_FIND_DATA FindFileData;

  if (utfdirPath == 0 || *utfdirPath == '\0') {
    return false;
  }

  TCHAR dirPath[MAX_PATH];
  TCHAR filename[MAX_PATH];

  StringCchCopy(dirPath, G_COUNTOF(dirPath), utfdirPath);
  StringCchCat(dirPath, G_COUNTOF(dirPath),
               TEXT("\\*"));  // searching all files
  StringCchCopy(filename, G_COUNTOF(filename), utfdirPath);
  StringCchCat(filename, G_COUNTOF(filename), TEXT("\\"));

  bool bSearch = true;

  hFind = FindFirstFile(dirPath, &FindFileData);  // find the first file
  if (hFind != INVALID_HANDLE_VALUE) {
    StringCchCopy(dirPath, G_COUNTOF(dirPath), filename);

    do {
      if ((lstrcmp(FindFileData.cFileName, TEXT(".")) == 0) ||
          (lstrcmp(FindFileData.cFileName, TEXT("..")) == 0)) {
        continue;
      }

      StringCchCopy(filename, G_COUNTOF(filename), dirPath);
      StringCchCat(filename, G_COUNTOF(filename), FindFileData.cFileName);
      if (FindFileData.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
        // we have found a directory, recurse
        if (!DeleteDirectory(filename)) {
          bSearch = false;
          break;  // directory couldn't be deleted
        }
      } else {
        if (FindFileData.dwFileAttributes & FILE_ATTRIBUTE_READONLY) {
          DWORD attribs = GetFileAttributes(filename);
          attribs &= ~FILE_ATTRIBUTE_READONLY;
          SetFileAttributes(filename, attribs);  // change read-only file mode
        }
        if (!DeleteFile(filename))  // delete the file
        {
          bSearch = false;
          break;
        }
      }
    } while (bSearch &&
             FindNextFile(hFind, &FindFileData));  // until we finds an entry

    if (bSearch) {
      if (GetLastError() != ERROR_NO_MORE_FILES)  // no more files there
      {
        bSearch = false;
      }
    }

    FindClose(hFind);  // closing file handle
  } else {  // Because on WinCE, FindFirstFile will fail for empty folder.
    // Other than that, we should not try to remove the directory then.
    if (GetLastError() != ERROR_NO_MORE_FILES)  // no more files there
    {
      bSearch = false;
    }
  }

  return (bSearch &&
          ::RemoveDirectory(utfdirPath));  // remove the empty directory
}
#endif
}  // namespace

bool Dir::Exists(const std::string& path) {
#if defined(_WIN32) && !defined(MINGW32)
#ifdef _UNICODE
  std::wstring wstr_path = ConvertStringToWideString(path);
  const TCHAR* syspath = wstr_path.c_str();
#else
  const TCHAR* syspath = path.c_str();
#endif  // _UNICODE

  // Returns RET_OK, only if it finds directory
  DWORD attributes = GetFileAttributes(syspath);
  if (attributes == INVALID_FILE_ATTRIBUTES) {
    return false;
  }

  return (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;

#else

  struct stat file_info;
  if (path.empty()) {
    return true;
  }

  //  Check whether the given path is directory
  if ((stat(path.c_str(), &file_info) == 0) && (S_ISDIR(file_info.st_mode))) {
    return true;
  }

  return false;
#endif  // _WIN32
}

bool Dir::exists(const std::string& path) { return Dir::Exists(path); }

bool Dir::Remove(const std::string& path) {
  bool ret = true;
#if defined(_WIN32) && !defined(__MINGW32__)
#ifdef _UNICODE
  std::wstring wstrPath = ConvertStringToWideString(path);
  const TCHAR* n_path = wstrPath.c_str();
#else
  const TCHAR* n_path = path.c_str();
#endif  // _UNICODE

  if (!DeleteDirectory(n_path)) {
    ret = false;
  }
#else
  if (nftw(path.c_str(), remove_dir_callback, 10, FTW_DEPTH | FTW_PHYS) != 0) {
    ret = false;
  }
#endif
  return ret;
}

bool Dir::remove(const std::string& path) { return Dir::Remove(path); }

bool Dir::Create(const std::string& path, bool extend_permissions) {
  if (exists(path)) {
    return true;
  }
  bool ret = true;
#if !defined(_WIN32) || defined(__MINGW32__)
  struct stat sbuf;
  if (stat(path.c_str(), &sbuf) != 0) {
    if (!mkdir_all(path.c_str(), extend_permissions ? 0777 : 0755)) {
      ret = false;
    }
  }
#else
  OLP_SDK_CORE_UNUSED(extend_permissions);

  std::string dir_path;
  std::string hyfon = path.substr(0, 1);
  bool b_relative_path = false;

  if (hyfon != "/" && hyfon != "\\") {
    b_relative_path = true;
  }

  std::vector<std::string> token;
  Tokenize(path, "\\", token);
  for (uint32_t t = 0; t < token.size(); ++t) {
    if (t > 0) {
      dir_path += "\\";
    } else {
      if (token[t].size() > 1) {
        hyfon = token[t].substr(1, 2);
        if (hyfon != ":" && !b_relative_path) {
          dir_path += "\\";
        }
      }
    }
    dir_path += token[t];
    if (!exists(dir_path)) {
#ifdef _UNICODE
      std::wstring wstrPath = ConvertStringToWideString(dir_path);
      const TCHAR* n_path = wstrPath.c_str();
#else
      const TCHAR* n_path = dir_path.c_str();
#endif  // _UNICODE

      if (!::CreateDirectory(n_path, NULL)) {
        if (GetLastError() != ERROR_ALREADY_EXISTS) {
          return false;
        }
      }
    }
  }
#endif
  return ret;
}

bool Dir::create(const std::string& path) { return Dir::Create(path); }

std::string Dir::TempDirectory() {
#if defined(_WIN32) && !defined(__MINGW32__)
  wchar_t path[MAX_PATH];
  ::GetTempPathW(MAX_PATH, path);

  // remove trailing /
  path[wcslen(path) - 1] = NULL;

  char buffer[MAX_PATH * 4];  // leave space for utf-8 characters
  ::WideCharToMultiByte(CP_UTF8, 0, path, -1, buffer, sizeof(buffer), NULL,
                        NULL);

  return buffer;
#elif defined(__ANDROID__)
  return "/sdcard/tmp";
#elif __APPLE__
#include "TargetConditionals.h"
#if TARGET_OS_IPHONE
  char* tmpDir = getenv("TMPDIR");
  auto ret = std::string{};
  if (tmpDir) {
    ret = std::string(tmpDir);
  }
  if (ret.empty()) {
    // default it to something more sensible, even though it probably won't work
    // it should never reach this path unless a big change in iOS
    ret = "/private/tmp";
  } else {
    if (ret[ret.size() - 1] == '/') {
      ret.pop_back();
    }
  }
  return ret;
#else
  // tmp is not world writable in OSX, but /private/tmp is
  return "/private/tmp";
#endif
#else
  return "/tmp";
#endif
}

bool Dir::FileExists(const std::string& file_path) {
#if defined(_WIN32) && !defined(__MINGW32__)
#ifdef _UNICODE
  std::wstring wstrPath = ConvertStringToWideString(file_path);
  const TCHAR* syspath = wstrPath.c_str();
#else
  const TCHAR* syspath = file_path.c_str();
#endif  // _UNICODE

  // If file not found attributes are 'INVALID_FILE_ATTRIBUTES'
  DWORD attributes = GetFileAttributes(syspath);
  return attributes != INVALID_FILE_ATTRIBUTES;

#else  // _WIN32

  if (file_path.empty()) {
    return false;
  }

  struct stat stat_info;

  return (0 == stat(file_path.c_str(), &stat_info)) &&
         S_ISREG(stat_info.st_mode);

#endif
}

uint64_t Dir::Size(const std::string& path, FilterFunction filter_fn) {
  uint64_t result = 0;

#if defined(_WIN32) && !defined(__MINGW32__)

  WIN32_FIND_DATAA find_data;
  std::string current_path = path + "\\*.*";

  HANDLE handle = FindFirstFileA(current_path.c_str(), &find_data);

  if (handle != INVALID_HANDLE_VALUE) {
    do {
      if (strcmp(find_data.cFileName, ".") == 0 ||
          strcmp(find_data.cFileName, "..") == 0) {
        continue;
      }

      if (find_data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
        current_path = path + "\\" + find_data.cFileName;
        result += Size(current_path, filter_fn);
      } else {
        if (filter_fn && !filter_fn(find_data.cFileName)) {
          continue;
        }

        LARGE_INTEGER size;
        size.LowPart = find_data.nFileSizeLow;
        size.HighPart = find_data.nFileSizeHigh;
        result += size.QuadPart;
      }
    } while (FindNextFileA(handle, &find_data) != 0);

    FindClose(handle);
  }

#else

  std::queue<std::string> recursive_queue;
  recursive_queue.push(path);

  auto iterate_directory = [&](const std::string& path) {
    auto* dir = ::opendir(path.c_str());
    if (dir == nullptr) {
      return;
    }

    struct ::dirent* entry = nullptr;
    while ((entry = ::readdir(dir)) != nullptr) {
      const char* entry_name = entry->d_name;

      if (strcmp(entry_name, ".") == 0 || strcmp(entry_name, "..") == 0) {
        continue;
      }

      std::string full_path = path + "/" + entry_name;

#ifdef __APPLE__
      struct ::stat path_stat;
      if (::lstat(full_path.c_str(), &path_stat) == 0) {
#else
      struct ::stat64 path_stat;
      if (::lstat64(full_path.c_str(), &path_stat) == 0) {
#endif
        if (S_ISREG(path_stat.st_mode)) {
          if (!filter_fn || filter_fn(entry_name)) {
            result += path_stat.st_size;
          }
        } else if (S_ISDIR(path_stat.st_mode)) {
          recursive_queue.push(std::move(full_path));
        }
      } else if (errno != ENOENT) {
        // Ignore ENOENT errors as its a common case, e.g. cache compaction.
        result = 0;
        break;
      }
    }

    ::closedir(dir);
  };

  while (!recursive_queue.empty()) {
    iterate_directory(recursive_queue.front());
    recursive_queue.pop();
  }

#endif

  return result;
}

bool Dir::IsReadOnly(const std::string& path) {
#if defined(_WIN32) && !defined(__MINGW32__)
#ifdef _UNICODE
  std::wstring wstrPath = ConvertStringToWideString(path);
  const TCHAR* syspath = wstrPath.c_str();
#else
  const TCHAR* syspath = path.c_str();
#endif  // _UNICODE

  // Read only flag is for files inside directory
  // CreateFile() winapi function will return handle to directory
  // so we need to check for ReadOnly attribute first.
  auto attributes = GetFileAttributes(syspath);
  if (attributes == INVALID_FILE_ATTRIBUTES) {
    return false;
  }

  if (attributes & FILE_ATTRIBUTE_DIRECTORY) {
    return (attributes & FILE_ATTRIBUTE_READONLY) == FILE_ATTRIBUTE_READONLY;
  }

  auto handle =
      CreateFile(syspath, GENERIC_WRITE,
                 FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                 OPEN_EXISTING, 0, NULL);

  if (handle == INVALID_HANDLE_VALUE) {
    return true;
  }
  CloseHandle(handle);
  return false;
#else
  return !(access(path.c_str(), W_OK) == 0 || errno == ENOENT);
#endif
}

}  // namespace utils
}  // namespace olp
