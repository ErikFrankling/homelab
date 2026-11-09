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
