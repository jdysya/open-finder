# PlantUML 图表源文件

这些图与 Markdown 中的 Mermaid 图表达相同的稳定边界，便于在 IDE、CI 或 PlantUML server 中独立渲染。

```bash
plantuml -checkonly docs/diagrams/*.puml
plantuml -tsvg docs/diagrams/*.puml
```

生成的 SVG/PNG 不提交到仓库；源文件与对应文档一起维护。

| 文件 | 对应文档 |
| --- | --- |
| `system-architecture.puml` | `docs/architecture.md` |
| `startup-recovery.puml` | `docs/architecture.md`、`docs/task-recovery.md` |
| `plugin-execution.puml` | `docs/plugin-system.md` |
