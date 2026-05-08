"""VM monthly cost estimation using the Azure Retail Prices REST API.

The user-approved architecture for the pricing agent is
``hosted_with_mcp_in_container`` — Node.js + ``@azure/mcp`` is bundled in
the agent image precisely so this tool *can* talk to the Azure MCP server
when desired. For the POC, however, we hit the same upstream the MCP
server itself proxies — the public ``prices.azure.com`` Retail Prices
API — directly. It needs no auth, no subprocess, and no JSON-RPC client,
which makes it the most reliable option for a function-call tool.

The Dockerfile still installs ``@azure/mcp`` so a future iteration can
swap in the MCP path without rebuilding the image.
"""
from __future__ import annotations

import logging
from typing import Any
from urllib.parse import quote

import urllib.request
import urllib.error
import json

logger = logging.getLogger("vmagent.pricing")

_RETAIL_PRICES_URL = "https://prices.azure.com/api/retail/prices"
_HOURS_PER_MONTH = 730  # standard Azure billing convention
_TIMEOUT_S = 20


def _http_get_json(url: str) -> dict[str, Any]:
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=_TIMEOUT_S) as resp:  # nosec B310
        return json.loads(resp.read().decode("utf-8"))


def get_vm_monthly_cost(
    vm_size: str,
    region: str = "australiaeast",
    os_type: str = "linux",
) -> dict[str, Any]:
    """Return an approximate monthly compute cost in AUD for a single VM.

    Args:
        vm_size: Azure VM SKU, e.g. ``Standard_D2s_v5`` (case-sensitive).
        region: Azure region short code, e.g. ``australiaeast``. Default
            australiaeast.
        os_type: ``linux`` or ``windows`` (case-insensitive). Used to
            disambiguate priced rows — Windows includes a Windows licence
            uplift, Linux does not.

    Returns:
        ``{ok, vm_size, region, os_type, hourly_aud, monthly_aud,
            currency, source, ...}`` on success;
        ``{ok: False, error}`` on failure.

    Compute-only estimate: managed disk, networking, snapshots, backup,
    and reserved-instance discounts are NOT included.
    """
    if not vm_size:
        return {"ok": False, "error": "vm_size is required"}

    os_lower = (os_type or "linux").strip().lower()
    if os_lower not in ("linux", "windows"):
        return {"ok": False, "error": f"os_type must be linux or windows; got {os_type!r}"}
    region_norm = (region or "australiaeast").strip().lower()

    # Filter for the consumption (PAYG) hourly meter for this exact SKU in
    # this exact region. We further narrow Linux vs Windows below.
    filt = (
        f"serviceName eq 'Virtual Machines' "
        f"and armSkuName eq '{vm_size}' "
        f"and armRegionName eq '{region_norm}' "
        f"and priceType eq 'Consumption'"
    )
    url = (
        f"{_RETAIL_PRICES_URL}?$filter={quote(filt)}"
        f"&currencyCode=AUD"
    )
    logger.info("pricing query vm_size=%s region=%s os=%s", vm_size, region_norm, os_lower)

    try:
        data = _http_get_json(url)
    except urllib.error.HTTPError as exc:
        return {"ok": False, "error": f"prices API HTTP {exc.code}: {exc.reason}"}
    except urllib.error.URLError as exc:
        return {"ok": False, "error": f"prices API unreachable: {exc.reason}"}
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": f"prices API error: {exc}"}

    items = data.get("Items") or []
    if not items:
        return {
            "ok": False,
            "error": (
                f"No retail prices found for SKU={vm_size} region={region_norm}. "
                "Check the SKU name and region are valid."
            ),
        }

    # Disambiguate Windows vs Linux. Windows VM rows include "Windows" in
    # the productName (e.g. "Virtual Machines DSv5 Series Windows"); Linux
    # rows do not. Also exclude spot/low-priority SKUs (skuName ends with
    # " Spot" / " Low Priority").
    def _is_windows(item: dict) -> bool:
        return "windows" in (item.get("productName") or "").lower()

    def _is_spot(item: dict) -> bool:
        sku = (item.get("skuName") or "").lower()
        return "spot" in sku or "low priority" in sku

    candidates = [it for it in items if not _is_spot(it)]
    if os_lower == "windows":
        matches = [it for it in candidates if _is_windows(it)]
    else:
        matches = [it for it in candidates if not _is_windows(it)]

    if not matches:
        return {
            "ok": False,
            "error": (
                f"No {os_lower} on-demand price found for SKU={vm_size} "
                f"region={region_norm}. Tried {len(candidates)} candidate rows."
            ),
        }

    # Pick the cheapest non-spot match (some SKUs have multiple meters
    # under the same product, e.g. different reservation terms).
    pick = min(matches, key=lambda it: float(it.get("retailPrice") or 0))
    hourly = float(pick.get("retailPrice") or 0)
    if hourly <= 0:
        return {"ok": False, "error": "retail price returned was zero"}

    monthly = round(hourly * _HOURS_PER_MONTH, 2)
    currency = pick.get("currencyCode") or "AUD"

    return {
        "ok": True,
        "vm_size": vm_size,
        "region": region_norm,
        "os_type": os_lower,
        "hourly_aud": round(hourly, 6),
        "monthly_aud": monthly,
        "currency": currency,
        "hours_per_month": _HOURS_PER_MONTH,
        "product_name": pick.get("productName"),
        "sku_name": pick.get("skuName"),
        "meter_name": pick.get("meterName"),
        "source": "Azure Retail Prices API (prices.azure.com)",
        "scope": "compute_only",
        "note": (
            "Compute-only estimate. Excludes managed disk, network egress, "
            "backups, snapshots, and reserved-instance discounts."
        ),
    }
