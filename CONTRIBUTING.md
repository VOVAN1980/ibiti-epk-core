
---

## C) GitHub Actions CI — `.github/workflows/ci.yml`

Создай папку и workflow:

```powershell
New-Item -ItemType Directory -Force .\.github\workflows | Out-Null

@'
name: CI

on:
  push:
    branches: [ "master", "main" ]
  pull_request:
    branches: [ "master", "main" ]

jobs:
  test:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1
        with:
          version: nightly

      - name: Forge fmt (check)
        run: forge fmt --check

      - name: Forge test
        run: forge test -vv
'@ | Set-Content -Encoding utf8 .\.github\workflows\ci.yml
