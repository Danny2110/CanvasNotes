# Notesy website

This static site is published from the `website/` directory by the GitHub Pages workflow at `.github/workflows/pages.yml`.

To publish it, push this repository to GitHub with the default branch named `main`, then set **Settings → Pages → Build and deployment → Source** to **GitHub Actions**. The workflow deploys on each push to `main` and can also be started from the Actions tab.

The interactive workspace is a front-end demo. Its notes live in the current page session and are not connected to the Notesy macOS app or iCloud.
