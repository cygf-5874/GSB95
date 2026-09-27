现有用例全绿，但那是因为它们都绕开了半开区间的边界。rangeset 是 Node.js 22 的
区间集合库（ESM，只用 node: 内置模块，没有第三方依赖），自检走 `scripts/check.sh`
（`check/` 是固定验收程序，别改）。

README 有「语义清单」7 条和「用例要求」一节；`src/rangeset.mjs` 是完整实现（本次不要改它），
`tests/smoke.test.mjs` 里 3 个冒烟用例当前全绿 —— 但按固定件算出来的杀伤率只有 0.32。

任务：补齐 `tests/` 下的用例，把杀伤率提到阈值以上，并让区分性要求也满足，固定件全过。

验收：
- node --test 退出码 0（仓库根目录裸跑；用例自身必须全绿）；
- bash scripts/check.sh 退出码 0，10 个场景全过（kill 3 + hygiene 3 + discriminate 2 + scale 2）。

约束：
1. 不改 `check/`、不改 `src/rangeset.mjs`；只在 `tests/` 下加用例。
2. 只通过公开 API 观察行为，不许读源码、字节码、文件哈希、行号，不许 import `_` 前缀私有符号。
3. 不许用定时器、`Math.random`、`Date.now` 让用例凑巧通过。
4. 只用 `node:` 内置模块，`package.json` 里不许出现 `dependencies`。
