# Changelog

## [0.8.13](https://github.com/kasdk3/sympozium/compare/v0.4.1...v0.8.13) (2026-04-05)


### Features

* add Cypress UX tests for instance creation and persona packs ([2ffb502](https://github.com/kasdk3/sympozium/commit/2ffb5026b82b116ab027c09bed58be9b9a02e8f1))
* add Cypress UX tests for instance creation and persona packs ([55e5590](https://github.com/kasdk3/sympozium/commit/55e5590af21dbea24e594ec7437052cc89ded4dc))
* add tool-call circuit breaker and configurable run timeout ([b5a3b94](https://github.com/kasdk3/sympozium/commit/b5a3b94cefeb6c7cf68a1c6f90181a2f45f28344))
* expose run timeout in web UI and CLI TUI ([3bca472](https://github.com/kasdk3/sympozium/commit/3bca472642dcf85df6a4f6d0f242f2ed08e3553e))
* **makefile:** add ux-tests-serve target for running Cypress against sympozium serve ([e9c3202](https://github.com/kasdk3/sympozium/commit/e9c3202d98105eff3d1b7d6008b9b4f7cd7a4d2e))
* **providers:** add Unsloth as a supported local LLM provider ([9c246c1](https://github.com/kasdk3/sympozium/commit/9c246c13ba8947b4fe026836e764786b43329126))
* recover qwen-native tool_calls from reasoning_content ([f807de1](https://github.com/kasdk3/sympozium/commit/f807de172243672997d25c3cd311740b34396fcb))


### Bug Fixes

* cascade-delete scheduled AgentRuns when their Schedule is removed ([eb1ad6a](https://github.com/kasdk3/sympozium/commit/eb1ad6af113686ae5b77c5d3b28c4ba9a913aabb))
* **personas:** harden platform-team prompts + propagate systemPrompt edits ([079986d](https://github.com/kasdk3/sympozium/commit/079986d5e8edc00cd85cf9ed4d715b36f85a589b))
* prevent reconcile race from overriding Succeeded AgentRuns as Failed ([d681a33](https://github.com/kasdk3/sympozium/commit/d681a3359f1d64ec2d8755402c0abe3849d96e8a))
* publish TopicAgentRunFailed from controller so web proxy unblocks on failure ([b98841f](https://github.com/kasdk3/sympozium/commit/b98841fe441a3c3f478640963c270fd7ed31dd85))
* remove conflicting namespace pre-creation in helm install ([9930ba4](https://github.com/kasdk3/sympozium/commit/9930ba4497989fa40d2461e9bef7039586c67aa0))
* resolve integration test hang and flaky secret-not-found error ([2fb431f](https://github.com/kasdk3/sympozium/commit/2fb431f99b42e14f6f123dbf6f62229ea3a06db0))
* run only smoke tests in CI integration workflow ([bf1c293](https://github.com/kasdk3/sympozium/commit/bf1c293374c6a90fa842f704d99efbad45783fdd))
* scheduler picks next free run-number suffix to avoid ghost runs ([205829a](https://github.com/kasdk3/sympozium/commit/205829a2c1525d2b2cf5fbdb09829b254790f601))
* skip Helm CreateNamespace when sympozium-system already exists ([e40b157](https://github.com/kasdk3/sympozium/commit/e40b157a238de6b91cd8f0e0e18c771eb66e5a0d))
* surface reasoning-model responses when terminal turn is empty ([045f7d7](https://github.com/kasdk3/sympozium/commit/045f7d74a2f95b5ebab7eba392c6d4441734368b))
* use sentinel value for run timeout Select to avoid Radix crash ([1553b75](https://github.com/kasdk3/sympozium/commit/1553b75912c1ed4037bd622de09abeaed57f290d))


### Miscellaneous Chores

* release 0.8.13 ([8a6fa7b](https://github.com/kasdk3/sympozium/commit/8a6fa7b870da36f0df6ab0bcccaeda6b1f04fec4))
