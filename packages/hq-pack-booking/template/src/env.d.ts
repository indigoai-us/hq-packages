declare module "virtual:booking-pages" {
  import type { ComponentType } from "preact";
  import type { PublicConfig } from "./lib/types.ts";
  /** Extra pages from overrides/pages/*.tsx. Each page component gets the public config. */
  const pages: { route: string; component: ComponentType<{ config: PublicConfig }> }[];
  export default pages;
}
