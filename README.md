# ReadyCheck

**ReadyCheck** makes debugging faster and clearer by capturing what happened and replaying it later.

## Get ReadyCheck

```sh
claude plugin marketplace add readycheck-dev/skills
claude plugin install readycheck@readycheck
```

This installs the **ReadyCheck** plugin from the dedicated ReadyCheck marketplace.
The marketplace ships the lightweight ReadyCheck plugin source directly, and that
plugin is pinned to a published GitHub release of the packaged macOS runtime.

## Use ReadyCheck

**Run and Analyze**

Option A: Say "check my app" or "check my macOS app".

OptionB: Run your app with `/check My app` or `/check My macOS app`.

This builds, runs, captures, and automatically analyzes your app.

**Analyze Only**

Run standalone analysis on an existing session, creating a fix plan.

```shell
/analyze [session_id]
```

**Supported Platforms and Programming Languages**

| | macOS | iOS | Android | Linux | Windows |
| --- | --- | --- | --- | --- | --- |
| Swift | ✅ | 📋 | 📋 | 📋 | 📋 |
| Objective-C | ✅ | 📋 | 📋 | 📋 | 📋 |
| C | ✅ | 📋 | 📋 | 📋 | 📋 |
| C++ | ✅ | 📋 | 📋 | 📋 | 📋 |
| Rust | ✅ | 📋 | 📋 | 📋 | 📋 |
| Kotlin | 📋 | 📋 | 📋 | 📋 | 📋 |
| Java | 📋 | 📋 | 📋 | 📋 | 📋 |

- ✅: Supported
- ⚠️: Not Tested
- 📋: Planned
- 🚧: Under construction

## Contributing Ideas

For now, ideas are submitted as GitHub issues.

If something feels missing or painful, open an issue with:

- What you were trying to do, what you expected, and what happened instead
- Your platform/version details
- (Optional) A redacted session bundle or screenshots/timestamps

## Contributing Tokens

This project is maintained by AI agents that continuously review contributed ideas and selectively implement them.

If you want to support the project's LLM-related costs (docs, examples, and evaluations), please open an issue to coordinate sponsorship or token contributions.

**Do not post API keys in issues.**

**Contributable Tokens:**

- Anthropic Claude series
- OpenAI GPT series
- Moonshot Kimi K2.6
- DeepSeek V4 series
- Xiaomi Mimo V2.5 Pro

## License

The plugin source code in this repository is licensed under the
[Apache License 2.0](LICENSES/Apache-2.0.txt).

Binary runtime packages downloaded by the plugin are licensed under the
[ReadyCheck Binary Preview License](LICENSES/ReadyCheck-Binary-Preview-License.txt).

Third-party components are listed in [LICENSES/THIRD-PARTY-NOTICES.md](LICENSES/THIRD-PARTY-NOTICES.md).

## Support

For issues or questions, please refer to the documentation or create an issue in the repository.
