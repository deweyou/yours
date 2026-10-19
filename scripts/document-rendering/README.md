# 离线文档渲染资源

从仓库根目录运行 `python3 scripts/document-rendering/build.py`。需要 Node/npm；安装与构建产物位于 `.build/document-rendering/`，依赖版本及传递依赖由此目录的 package-lock.json 锁定。

脚本更新 `Sources/Yours/Resources/DocumentRendering/` 中 Mermaid、KaTeX、字体、许可证与校验值。`index.html` 和 `render.js` 是应用维护的宿主文件，不覆盖。提交依赖更新时一起检查许可证和离线渲染测试。应用运行不使用 npm、CDN 或网络请求。

发布资源通过 esbuild 去除 console 与 debugger；解析异常仍由渲染桥接捕获并展示，不依赖浏览器控制台。
