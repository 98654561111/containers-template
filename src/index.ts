import { Container, getContainer, getRandom } from "@cloudflare/containers";
import { Hono } from "hono";

export class MyContainer extends Container<Env> {
	// Status page served by python http.server inside the container
	defaultPort = 7860;

	// Nested QEMU VM takes a long time to boot; keep the container warm
	sleepAfter = "1h";

	// Internet required for apt, Tailscale, cloud image fallback, etc.
	enableInternet = true;

	constructor(ctx: DurableObjectState, env: Env) {
		// DurableObjectState generic defaults differ slightly from the base class
		super(ctx as ConstructorParameters<typeof Container>[0], env);

		// Baseline + secrets/vars from the Worker binding
		this.envVars = {
			STATUS_PORT: "7860",
			VM_RAM: "8192",
			VM_SMP: "4",
			VM_DISK_SIZE: "10G",
			VM_SSH_PORT: "2222",
			UBUNTU_RELEASE: "noble",
			VM_ROOT_PASSWORD: env.VM_ROOT_PASSWORD ?? "changeme",
			TS_HOSTNAME: env.TS_HOSTNAME ?? "modelscope-ubuntu",
			VM_NAME: env.VM_NAME ?? "ubuntu-vm",
			...(env.TS_AUTHKEY ? { TS_AUTHKEY: env.TS_AUTHKEY } : {}),
			...(env.VM_SSH_PUBKEY ? { VM_SSH_PUBKEY: env.VM_SSH_PUBKEY } : {}),
		};
	}

	override onStart() {
		console.log("Container successfully started (QEMU + status page)");
	}

	override onStop() {
		console.log("Container successfully shut down");
	}

	override onError(error: unknown) {
		console.log("Container error:", error);
	}
}

// Create Hono app with proper typing for Cloudflare Workers
const app = new Hono<{
	Bindings: Env;
}>();

// Home route with available endpoints
app.get("/", (c) => {
	return c.text(
		"Ubuntu VM Container endpoints:\n" +
			"GET /container/<ID>  - Start a dedicated QEMU Ubuntu VM container\n" +
			"GET /lb              - Load balance over multiple containers\n" +
			"GET /singleton       - Single shared container instance\n" +
			"\n" +
			"The response is the container status page (port 7860).\n" +
			"SSH into the nested VM via Tailscale (set TS_AUTHKEY secret).\n",
	);
});

// Route requests to a specific container using the container ID
app.get("/container/:id", async (c) => {
	const id = c.req.param("id");
	const container = getContainer(c.env.MY_CONTAINER, id);
	return await container.fetch(c.req.raw);
});

// Forward all methods/paths under /container/:id to the container
app.all("/container/:id/*", async (c) => {
	const id = c.req.param("id");
	const container = getContainer(c.env.MY_CONTAINER, id);
	return await container.fetch(c.req.raw);
});

// Load balance requests across multiple containers
app.get("/lb", async (c) => {
	const container = await getRandom(c.env.MY_CONTAINER, 2);
	return await container.fetch(c.req.raw);
});

// Get a single container instance (singleton pattern)
app.get("/singleton", async (c) => {
	const container = getContainer(c.env.MY_CONTAINER);
	return await container.fetch(c.req.raw);
});

app.all("/singleton/*", async (c) => {
	const container = getContainer(c.env.MY_CONTAINER);
	return await container.fetch(c.req.raw);
});

export default app;
