#ifndef RUNNER_UTILS_H_
#define RUNNER_UTILS_H_

#include <string>
#include <vector>

// Creates a console for the process, and redirects stdout and stderr to
// it for both the runner and the Flutter library.
void CreateAndAttachConsole();

// Takes a null-terminated wchar_t* encoded in UTF-16 and returns a std::string
// encoded in UTF-8. Returns an empty std::string on failure.
std::string Utf8FromUtf16(const wchar_t* utf16_string);

// Takes a std::string encoded in UTF-8 and returns a std::wstring encoded in
// UTF-16. Returns an empty std::wstring on failure.
//
// 反方向的那一个（[Utf8FromUtf16]）是 runner 模板自带的（处理命令行参数用）；
// 这个反方向的是给「Dart 传来的标题」用的 —— Dart 的字符串走通道过来是
// UTF-8，而 `SetWindowTextW` 只认 UTF-16。
std::wstring Utf16FromUtf8(const std::string& utf8_string);

// Gets the command line arguments passed in as a std::vector<std::string>,
// encoded in UTF-8. Returns an empty std::vector<std::string> on failure.
std::vector<std::string> GetCommandLineArguments();

#endif  // RUNNER_UTILS_H_
