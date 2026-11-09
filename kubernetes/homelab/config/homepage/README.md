# Home

The live start page is `index.html`, served directly by upstream nginx at
https://home.erikfrankling.duckdns.org. Add service links to the relevant
section of that HTML file whenever adding a route. All 31 original links
are retained. The search form works without JavaScript.

No build, JavaScript, remote icons, fonts, or API requests are needed. Keep
it that way: links must render in the first response. The Health link opens
Gatus instead of making the start page poll its API. `nginx.conf` enables
compression and browser revalidation. Kustomize hashes these two files into
the ConfigMap name, so edits trigger a rolling deployment through Flux.

The old Homepage YAML/CSS/JS files are historical reference only and are no
longer deployed. They are not the source of the live links.

## Appearance and bundled assets

Use the compact dark dashboard layout, original service logos, and the bundled
Inter font. Erik explicitly asked to keep logos and make the page look polished.
Do not strip it back to plain text tiles to save bytes. All assets are embedded
in the HTML, so there are still no network dependencies or rendering gates.
The system's sans-serif maps to JetBrains Mono, hence the embedded Inter font.

Logos are from the previous Homepage service configuration: MDI SVG 7.4.47
(https://github.com/Templarian/MaterialDesign-SVG), and Dashboard Icons
(https://github.com/homarr-labs/dashboard-icons). Raster logos are downsampled
to 64px lossless WebP; SVG icons and the Inter Latin regular WOFF2 are embedded
as data URLs. Font source: https://fontsource.org/fonts/inter. See bundled
LICENSE files; brand marks remain the property of their respective owners.
