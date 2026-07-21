# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Commands

```bash
# Start development server
rails s

# Webpack asset compilation
bin/webpack                  # one-time build
bin/webpack-dev-server       # dev server with HMR (port 3035)
rails assets:precompile      # production build

# Database
rails db:migrate
rails db:schema:load
rails db:seed

# Tests (Minitest + Capybara)
rails test                        # all tests
rails test test/models/user_test.rb   # single test file
rails test:system                 # system/browser tests

# Dependencies
bundle install
yarn install
```

## Architecture

**Rails 7.1 / Ruby 3.2 / PostgreSQL admin dashboard** for customer analytics and profile management. Data comes from Shopify/Shopline CSV exports, gets enriched with custom metadata, and is visualized via the SmartAdmin Bootstrap 4.3 template. Frontend assets go through Webpacker (legacy webpack integration).

### Core Data Flow

**Import → Enrich → Cache → Report**

1. **Import**: XLSX/CSV files uploaded via UI → `PaidOrdersWorkbookImporter` / `CustomersReportImporter` (Roo gem) → runs in background via `ImportCustomersJob`
2. **Enrich**: `ShoplineCustomer` records get supplemental data in `CustomerProfile` (tags, notes, brand ambassador flag)
3. **Cache**: `CustomerPurchaseSummaryRefreshService` and `CustomerSeriesLoyaltyRefreshService` materialize denormalized analytics into `customer_purchase_summaries` and `customer_series_loyalties` tables
4. **Report**: Controllers query cached tables; supports CSV/Excel exports for inactive/expired customers

### Key Models

| Model | Purpose |
|---|---|
| `ShoplineCustomer` | Imported Shopify order data (primary entity) |
| `ShoplineOrder` | Line items linked to a customer |
| `CustomerProfile` | Enriched metadata — tags, notes, ambassador status |
| `CustomerPurchaseSummary` | Denormalized analytics cache (regenerated via service) |
| `CustomerSeriesLoyalty` | Per-series purchase tracking cache |
| `Album` / `Photo` | Customer photo albums; photos stored on Cloudinary |
| `SidebarEntry` | Database-driven sidebar navigation items |

### Services (`app/services/`)

- `analytics/ProductAnalysis` — product-level metrics
- `importing/` — CSV/XLS parsing logic (separate from jobs)
- `*RefreshService` — scheduled recalculation of cached analytics tables

### Controllers of Note

`CustomersController` is the core — filterable/sortable customer list backed by the analytics cache. `WelcomeController` drives the main dashboard. Dedicated controllers exist for analytical views: `LoyalCustomersController`, `FirstPurchaseController`, `HighSpendersController`.

### Database Patterns

- GIN indexes on PostgreSQL array columns (`product_tags`, `health_tags`) for tag-based filtering
- Denormalized summary tables are the query target, not the raw `shopline_orders` table
- Array column usage requires Rails array-type query helpers

### Frontend

- SmartAdmin v4.0.3 template (Bootstrap 4.3); hundreds of demo/showcase routes exist under `GET /pages/*`
- Chart.js 4.5 for visualizations; Turbolinks 5 for navigation
- Page-specific JS/CSS injected via `content_for :head_block` and `content_for :scripts_block`
- Webpacker entry point: `app/javascript/packs/application.js`

### Authentication

Devise handles auth (sessions only — no self-registration). Single `User` model with email + username. No role-based access control.

### Environment Configuration

- `config/application.rb` contains SmartAdmin feature flags (sidebar, footer, chat, shortcuts) under `config.x.*`
- Cloudinary credentials go in environment variables (initialized in `config/initializers/`)
- `config/database.yml` targets PostgreSQL for all environments
