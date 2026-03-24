# confluence-exporter

A bash tool for exporting Confluence pages to Markdown, HTML, or raw storage XML.

Supports two modes:
- **API mode** — authenticated export via the Confluence REST API (Cloud or Server/Data Center)
- **Scraper mode** — unauthenticated HTML scraping for public pages (single page only)

## Requirements

| Tool | Required | Without it |
|------|----------|------------|
| `curl` | Yes | Tool will not run |
| `jq` | No | JSON parsing falls back to sed/grep (less reliable) |
| `pandoc` | No | Markdown conversion uses built-in sed/awk converter (degraded output) |

Install optional dependencies on macOS:
```bash
brew install jq pandoc
```

## Installation

```bash
git clone https://github.com/yourname/confluence-exporter
cd confluence-exporter
chmod +x confluence-export.sh
```

Optionally install to your PATH:
```bash
make install          # copies to /usr/local/bin/confluence-export
```

## Configuration

Set credentials via environment variables or a `.confluencerc` file in your project directory or `$HOME`.

### Environment variables

```bash
export CONFLUENCE_URL=https://yoursite.atlassian.net   # required
export CONFLUENCE_TYPE=cloud                            # cloud (default) or server
export CONFLUENCE_AUTH_TYPE=basic                       # basic (default) or bearer
export CONFLUENCE_EMAIL=you@example.com                 # Cloud basic auth
export CONFLUENCE_TOKEN=your_api_token                  # Cloud basic auth or Server bearer
export CONFLUENCE_USERNAME=admin                        # Server basic auth
export CONFLUENCE_PASSWORD=secret                       # Server basic auth
```

### .confluencerc file

```ini
CONFLUENCE_URL=https://yoursite.atlassian.net
CONFLUENCE_TYPE=cloud
CONFLUENCE_EMAIL=you@example.com
CONFLUENCE_TOKEN=your_api_token
```

See `.env.example` for all available options.

### Getting an API token

**Confluence Cloud:** Go to https://id.atlassian.com/manage-profile/security/api-tokens → Create API token.

**Confluence Server/Data Center:** Use your password, or create a Personal Access Token under your profile settings (Server 7.9+ / DC 7.9+).

## Usage

```
./confluence-export.sh [OPTIONS]
```

### Scope (one required)

```bash
--page <url|id>        Export a single page
--recursive <url|id>   Export a page and all its descendants
--space <SPACE_KEY>    Export all pages in a space
```

### Format

```bash
--format md            Markdown (default)
--format html          Rendered HTML
--format raw           Confluence storage XML
```

### Other options

```bash
--output <dir>         Output directory (default: ./export)
--force                Overwrite existing files
--depth <n>            Limit recursive export depth
--list                 Dry run: print what would be exported without writing files
--mode api|scraper     Force a specific mode
--scraper-fallback     Fall back to scraper mode on auth failure (401/403)
--debug                Verbose debug output
```

## Examples

### Export a single page (Cloud)

```bash
export CONFLUENCE_URL=https://yoursite.atlassian.net
export CONFLUENCE_EMAIL=you@example.com
export CONFLUENCE_TOKEN=your_api_token

./confluence-export.sh --page 12345 --format md
# or pass the full URL
./confluence-export.sh --page https://yoursite.atlassian.net/wiki/spaces/KEY/pages/12345/Page-Title
```

### Export a page and all children recursively

```bash
./confluence-export.sh --recursive 12345 --format md --output ./docs
```

### Export an entire space

```bash
./confluence-export.sh --space MYSPACE --format md --output ./export
```

### Limit recursive depth

```bash
./confluence-export.sh --recursive 12345 --depth 2 --format md
```

### Dry run — see what would be exported

```bash
./confluence-export.sh --space MYSPACE --list
```

### Export a public page without credentials (scraper mode)

```bash
./confluence-export.sh \
  --mode scraper \
  --page https://yoursite.atlassian.net/wiki/spaces/KEY/pages/12345/Title \
  --format md
```

### Try API first, fall back to scraper on auth failure

```bash
./confluence-export.sh --page 12345 --scraper-fallback --format md
```

### Export from Server/Data Center

```bash
export CONFLUENCE_URL=https://confluence.example.com
export CONFLUENCE_TYPE=server
export CONFLUENCE_USERNAME=admin
export CONFLUENCE_TOKEN=your_pat   # or use CONFLUENCE_PASSWORD

./confluence-export.sh --page 12345 --format md
```

## Output structure

Pages are written to a directory hierarchy mirroring the page tree:

```
export/
└── SPACEKEY/
    ├── parent-page.md
    └── parent-page/
        ├── child-page-one.md
        └── child-page-two.md
```

Page titles are slugified (lowercased, spaces to hyphens, special characters stripped). If two pages produce the same slug, the page ID is appended: `my-page--12345.md`.

## API vs scraper mode

| Capability | API mode | Scraper mode |
|---|---|---|
| Single page | Yes | Yes |
| Recursive export | Yes | No |
| Full space export | Yes | No |
| Markdown output | Yes | Yes (degraded without pandoc) |
| HTML output | Yes | Yes |
| Raw storage XML | Yes | No |
| Requires credentials | Yes | No |
| Pagination | Yes | N/A |

Scraper mode is limited to single pages and cannot enumerate children — that information is only available through the API.

## Running tests

```bash
make test              # unit + integration
make test-unit
make test-integration
```

Tests use [bats-core](https://github.com/bats-core/bats-core) and a Python fixture server — no real Confluence instance needed.

```bash
make install-deps      # brew install bats-core jq pandoc shellcheck
```

## Linting

```bash
make lint              # runs shellcheck on all .sh files
```
