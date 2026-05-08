"""Validate Azure region codes for VM deployment.

The Azure Retail Prices API returns one row per (SKU, region) tuple. By
querying for a single ubiquitous VM SKU we can enumerate every public
region that sells Virtual Machines — which is exactly the set we need to
validate user-supplied region codes against.

This source needs no auth (so it works for the pricing agent too, which
has no subscription wired in) and stays in sync with Microsoft's actual
GA region list automatically.
"""
from __future__ import annotations

import difflib
import json
import logging
import threading
import time
import urllib.error
import urllib.request
from typing import Any
from urllib.parse import quote

logger = logging.getLogger("vmagent.regions")

_RETAIL_PRICES_URL = "https://prices.azure.com/api/retail/prices"
_TIMEOUT_S = 20
# Standard_B2s is sold in essentially every public region (incl. NZ North,
# Italy North, Spain Central, etc.). Using one ubiquitous SKU keeps the
# response small (~70 rows) and the answer authoritative.
_PROBE_SKU = "Standard_B2s"

# Cache for the process lifetime; refresh occasionally in case Azure adds
# a new region during a long-lived container.
_CACHE_TTL_S = 6 * 60 * 60
_cache_lock = threading.Lock()
_cache: dict[str, Any] = {"regions": None, "loaded_at": 0.0}


def _http_get_json(url: str) -> dict[str, Any]:
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=_TIMEOUT_S) as resp:  # nosec B310
        return json.loads(resp.read().decode("utf-8"))


def _fetch_vm_regions() -> list[str]:
    """Hit the retail prices API and return the distinct armRegionName set."""
    filt = (
        f"serviceName eq 'Virtual Machines' "
        f"and armSkuName eq '{_PROBE_SKU}' "
        f"and priceType eq 'Consumption'"
    )
    url = f"{_RETAIL_PRICES_URL}?$filter={quote(filt)}"
    regions: set[str] = set()
    pages = 0
    while url and pages < 20:  # hard safety cap
        data = _http_get_json(url)
        for it in data.get("Items") or []:
            r = (it.get("armRegionName") or "").strip().lower()
            if r:
                regions.add(r)
        url = data.get("NextPageLink") or ""
        pages += 1
    out = sorted(regions)
    logger.info("loaded %d Azure VM regions from retail prices API", len(out))
    return out


def _get_regions(force_refresh: bool = False) -> list[str]:
    with _cache_lock:
        now = time.time()
        regions = _cache["regions"]
        loaded_at = _cache["loaded_at"]
        fresh = regions is not None and (now - loaded_at) < _CACHE_TTL_S
        if fresh and not force_refresh:
            return regions  # type: ignore[return-value]
    # Fetch outside the lock so concurrent callers don't all serialise.
    try:
        fetched = _fetch_vm_regions()
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as exc:
        logger.warning("retail prices region fetch failed: %s", exc)
        with _cache_lock:
            cached = _cache["regions"]
            if cached:
                return cached  # type: ignore[return-value]
        raise
    with _cache_lock:
        _cache["regions"] = fetched
        _cache["loaded_at"] = time.time()
    return fetched


def validate_region(region: str) -> dict[str, Any]:
    """Validate that ``region`` is a real Azure region that sells VMs.

    Returns a dict with:
      ``ok``         — True if the lookup succeeded (whether or not the
                       region is valid).
      ``valid``      — True if the supplied region matches a known Azure
                       VM region.
      ``region``     — Normalised input (lowercased + trimmed).
      ``suggestions``— On invalid input, up to 5 close matches.
      ``count``      — Total number of Azure VM regions known.
      ``source``     — Where the list came from.
    """
    region_in = region or ""
    region_norm = region_in.strip().lower().replace(" ", "")
    if not region_norm:
        return {"ok": False, "error": "region is required"}

    try:
        regions = _get_regions()
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": f"could not load Azure region list: {exc}"}

    if region_norm in regions:
        return {
            "ok": True,
            "valid": True,
            "region": region_norm,
            "count": len(regions),
            "source": "Azure Retail Prices API (prices.azure.com)",
        }

    suggestions = difflib.get_close_matches(region_norm, regions, n=5, cutoff=0.5)
    return {
        "ok": True,
        "valid": False,
        "region": region_norm,
        "suggestions": suggestions,
        "count": len(regions),
        "source": "Azure Retail Prices API (prices.azure.com)",
        "hint": (
            "Use the Azure 'short' region code (e.g. australiaeast, eastus, "
            "newzealandnorth), all lowercase, no spaces."
        ),
    }


def list_azure_vm_regions() -> dict[str, Any]:
    """Return the full list of Azure regions that sell Virtual Machines."""
    try:
        regions = _get_regions()
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": f"could not load Azure region list: {exc}"}
    return {
        "ok": True,
        "regions": regions,
        "count": len(regions),
        "source": "Azure Retail Prices API (prices.azure.com)",
    }
