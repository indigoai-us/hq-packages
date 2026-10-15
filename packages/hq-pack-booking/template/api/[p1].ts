// Every /api route with 1 path segment after /api comes here; the app's own
// router (api/_lib/http.ts) matches the full path. See knowledge/booking/hosting.md.
import { serveDeployed } from "./_lib/deployed.ts";

export default serveDeployed;
