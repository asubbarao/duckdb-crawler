//! Rust HTML Parser FFI for DuckDB Crawler Extension
//!
//! Provides extraction capabilities for:
//! - JSON-LD structured data
//! - Microdata (schema.org)
//! - OpenGraph meta tags
//! - Meta tags
//! - CSS selectors (jQuery-like syntax)
//! - robots.txt parsing
//! - Sitemap XML parsing
//! - SPA hydration state (Next.js, Nuxt, Pinia, Apollo)

mod extractors;
mod ffi;
pub mod hydration;
pub mod robots;
pub mod sitemap;

pub use ffi::*;
