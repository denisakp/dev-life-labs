# Dev Life Labs

Companion code for the articles published on [denisakp.me](https://denisakp.me).

Each folder is a self-contained lab tied to one blog post — runnable scripts,
configs, and examples you can clone and execute as you read along. No fluff,
no framework: plain, reproducible setups.

## Layout

```
dev-life-labs/
├── postgresql-ha-cluster/   # 3-node PostgreSQL HA cluster (Patroni + etcd + HAProxy + Keepalived)
└── mongo-replica/         # MongoDB replica set with Docker Compose
```

## How to use

Clone once, then `cd` into the lab for the article you're reading:

```bash
git clone https://github.com/denisakp/dev-life-labs
cd dev-life-labs/postgresql-ha-cluster
```

Each lab carries its own README (or guide) with prerequisites and step-by-step
usage. Start there.

## Labs

| Lab | Article | What it does |
| --- | --- | --- |
| [postgresql-ha-cluster](./postgresql-ha-cluster) | [Setting up a PostgreSQL HA cluster](https://denisakp.me/blog/databases/postgres/set-up-postgresql-ha-cluster-with-patroni) | Highly available 3-node PostgreSQL with automatic failover |
| [mongo-replica](./mongo-replica) | [MongoDB replica set with Docker](https://denisakp.me/blog/databases/mongo/set-up-mongodb-replica-set-with-docker) | 3-node MongoDB replica set from a custom image |

<!-- add a row per lab as the blog grows -->

## Conventions

- One folder per article, named after the post slug.
- Every lab is idempotent where it makes sense — re-running a deploy script
  should not break an existing setup.
- Secrets live in a `*.env.example` template; copy it to `*.env` and fill it in.
  Real `.env` files are git-ignored and never committed.
- Scripts target Debian/Ubuntu unless a lab's README says otherwise.

## Versioning

Scripts evolve. When an article needs a frozen version, it links to a tagged
release or a specific commit, so the steps in the post always match the code.

## Disclaimer

These labs are teaching material. Review every script before running it, and
harden before any production use — defaults favor clarity over lockdown.

## License

[MIT](./LICENSE)
