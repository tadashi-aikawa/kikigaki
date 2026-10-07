import { defineCollection } from "astro:content";
import { docsLoader, i18nLoader } from "@astrojs/starlight/loaders";
import { docsSchema, i18nSchema } from "@astrojs/starlight/schema";

export const collections = {
  docs: defineCollection({ loader: docsLoader(), schema: docsSchema() }),
  // UIの文言はStarlight同梱の日本語を使う。コレクションが無いとビルドが警告を出すため空の上書きを置く
  i18n: defineCollection({ loader: i18nLoader(), schema: i18nSchema() }),
};
