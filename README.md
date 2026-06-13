# Windows AppLock (Flutter + Win32)

A lightweight, system-level desktop security utility that leverages the native Windows API to monitor background processes and intercept application launches with a secure, responsive Flutter overlay. 

This project was built using an **AI-assisted rapid prototyping workflow**, where I acted as the primary architect and systems designer—mapping out the process-hooking logic, data architecture, and user journey, while orchestrating advanced AI tools to generate the underlying low-level code implementation.

---

## 🚀 Core Features

* **Real-Time Process Monitoring:** Utilizes the native `win32` API to continuously scan and match active OS-level background processes against a user-defined blocklist.
* **Seamless Window Interception:** Instantly triggers a borderless, un-bypassable Flutter overlay screen to lock out unauthenticated users the moment a target app launches.
* **Biometric & Secure Authentication:** Integrated framework designed to hook into Windows Hello (biometrics/PIN) and local cryptographic authentication.
* **Zero-Knowledge Architecture:** Designed with local encryption in mind, ensuring user configuration and lock parameters never leave the machine.

---

## 🛠️ Tech Stack & Workflow

* **Framework:** Flutter (Desktop)
* **Language:** Dart
* **OS Integration:** Native `win32` package / Windows API hooks
* **Development Methodology:** AI-Assisted Development / Rapid Architecture Prototyping

---

## 🧠 Architectural Insights (How It Works)

1. **The Watcher:** A low-overhead background thread hooks into the Windows process lifecycle.
2. **The Matcher:** Incoming process IDs (PIDs) are checked against an encrypted local configuration database.
3. **The Interceptor:** If a match is flagged, the application invokes a top-level native window handle (`HWND`) to drop a full-screen Flutter authentication interface over the target app, restricting input until valid credentials are provided.

---

## 📌 Development Philosophy
This project serves as a practical case study in **modern, AI-accelerated engineering**. By leveraging AI tools to handle tedious boilerplate and complex Win32 bindings, development time was cut down by over 70%, allowing a single developer to focus strictly on system logic, security edge-cases, and application performance.
