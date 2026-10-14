#pragma once
#include <windows.h>
#include <vector>

class CW2A {
public:
    LPSTR m_psz;
    CW2A(LPCWSTR str, UINT codePage = CP_THREAD_ACP) : m_psz(nullptr) {
        if (str) {
            int len = WideCharToMultiByte(codePage, 0, str, -1, nullptr, 0, nullptr, nullptr);
            if (len > 0) {
                m_buf.resize(len);
                WideCharToMultiByte(codePage, 0, str, -1, m_buf.data(), len, nullptr, nullptr);
                m_psz = m_buf.data();
            }
        }
    }
    CW2A(const CW2A&) = delete;
    CW2A& operator=(const CW2A&) = delete;

    operator LPCSTR() const { return m_psz ? m_psz : ""; }
    operator LPSTR() { return m_psz; }
private:
    std::vector<char> m_buf;
};

class CA2W {
public:
    LPWSTR m_psz;
    CA2W(LPCSTR str, UINT codePage = CP_THREAD_ACP) : m_psz(nullptr) {
        if (str) {
            int len = MultiByteToWideChar(codePage, 0, str, -1, nullptr, 0);
            if (len > 0) {
                m_buf.resize(len);
                MultiByteToWideChar(codePage, 0, str, -1, m_buf.data(), len);
                m_psz = m_buf.data();
            }
        }
    }
    CA2W(const CA2W&) = delete;
    CA2W& operator=(const CA2W&) = delete;

    operator LPCWSTR() const { return m_psz ? m_psz : L""; }
    operator LPWSTR() { return m_psz; }
private:
    std::vector<wchar_t> m_buf;
};
