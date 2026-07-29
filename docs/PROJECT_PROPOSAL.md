# MoonPart 项目申报书

## 基本信息

项目名称：MoonPart：面向 MoonBit 的流式 multipart/form-data 基础库  

参赛者：Eisem  

联系方式：待填写（手机号或邮箱）  

GitHub 仓库链接：[https://github.com/Eisem/MoonPart](https://github.com/Eisem/MoonPart)  

项目方向：MoonBit 网络协议基础库 / 文件上传与工程基础设施  

是否为移植项目：否（原创实现；参考 RFC 7578、RFC 2046 的协议语义）  

## 项目简介

MoonPart 计划为 MoonBit 生态提供一个可复用、可流式处理、二进制安全的
`multipart/form-data` 基础库。该协议是 HTTP 表单与文件上传的通用基础，但在
实际服务中常遇到大文件导致的内存压力、网络分块切割边界、恶意或歧义头部、
文件名路径注入以及不同后端行为不一致等问题。

项目面向 HTTP 框架适配者、Web/CLI 工具开发者、对象存储上传服务和需要构造
multipart 请求的 MoonBit 应用。它提供完整小表单解析、增量事件解析、文件
sink 交付、表单收集和流式二进制编码能力，使使用者可以在不缓存完整上传文件
的情况下安全地处理或生成 multipart 请求体。

## 核心功能与实施方案

- 提供 `Parser`、`StreamingParser` 与 `decode_bytes`：支持任意网络分块、
  边界跨 chunk、文本表单和原始 `Bytes` 文件内容。
- 提供 `FormDataCollector`、`StreamingFormCollector` 和
  `StreamingFormDecoder`：小表单可直接收集，大文件通过 `FileSinkEvent`
  增量转交给应用侧文件系统、对象存储或哈希计算器。
- 提供 `StreamingEncoder`：以 `PartBegin / PartData / PartEnd / Finished`
  事件生成可立即写出的二进制块，避免编码阶段聚合整个请求体。
- 实现严格的 `Content-Type`、boundary、`Content-Disposition`、name、filename
  和头部校验；拒绝重复参数、重复关键头、CRLF 注入与非法事件序列。
- 提供 body、part、header、字段、文件数及单字段大小限制，支持允许字段白名单
  和逐字段限额；上传路径由应用侧控制，库仅提供文件名 basename 辅助函数。
- 提供 README 可运行示例、原生 benchmark、Wasm/Wasm-GC/JavaScript/native
  四后端 CI、测试与覆盖率报告，并维护变更日志和设计说明。

## 技术路线与交付目标

项目使用 MoonBit 原生类型系统、包结构、测试框架和统一工具链实现，不依赖
第三方 multipart 运行时。解析器以显式状态机维护 opening boundary、headers、
body 与 finished 状态，仅保留可能组成下一条 boundary 的后缀；编码器使用对偶
事件状态机，直接透传二进制 `PartData`。核心数据结构和状态均封装在公开 API
之后，避免调用方破坏状态机不变量。

最终交付包括：公开 GitHub 与 Gitlink 同步仓库、Apache-2.0 许可证、完整 README
和设计文档、至少一个可运行示例、持续集成配置、可运行测试及 benchmark、发布到
mooncakes.io 的包版本。当前仓库已具备 48 个可追踪提交、39 项四后端测试、
88.5% 覆盖率、可生成发布包的工程基础；后续将继续完善高层表单构造 API、
互操作测试与发布流程。

## 原创与合规说明

MoonPart 不复制其他语言的实现代码，协议行为仅参考 RFC 7578 和 RFC 2046。
项目采用 Apache-2.0 许可证；当前实现不引入第三方模块依赖。经 mooncakes.io
生态重名与关键词检查，未发现已发布的同类 MoonBit multipart/form-data 包。项目
以 MoonBit 为主要实现语言，功能边界聚焦 multipart 协议处理，不包含 HTTP
传输、异步 I/O、临时文件管理、病毒扫描或可信存储路径等应用层能力。
