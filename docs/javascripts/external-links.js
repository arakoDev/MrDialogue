(function () {
  function openExternalLinksInNewTab() {
    document.querySelectorAll("a[href]").forEach(function (link) {
      var url;

      try {
        url = new URL(link.href, window.location.href);
      } catch (_error) {
        return;
      }

      if (
        (url.protocol !== "http:" && url.protocol !== "https:") ||
        url.origin === window.location.origin
      ) {
        return;
      }

      link.target = "_blank";

      var rel = new Set(
        (link.getAttribute("rel") || "").split(/\s+/).filter(Boolean)
      );
      rel.add("noopener");
      rel.add("noreferrer");
      link.setAttribute("rel", Array.from(rel).join(" "));
    });
  }

  if (typeof document$ !== "undefined") {
    document$.subscribe(openExternalLinksInNewTab);
  } else if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", openExternalLinksInNewTab);
  } else {
    openExternalLinksInNewTab();
  }
})();
