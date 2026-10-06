# Maintaining

## Publish a new version

1. Bump `VERSION` in `lib/soml/version.rb`.
2. Commit and push: `git commit -am "1.2.3" && git push`
3. Run the [Release workflow](.github/workflows/release.yml): `gh workflow run release.yml`. It tests, publishes the gem with [trusted publishing](https://guides.rubygems.org/trusted-publishing/), and pushes the `v1.2.3` tag.
4. Create a release on GitHub.
