// MCP servers page: verify list renders. If an "Add" flow exists in the
// UI, it's attempted best-effort; otherwise the API path is used to
// create a dummy server and the test verifies it surfaces in the list.

const SERVER = `cy-mcp-${Date.now()}`;

function authHeaders(): Record<string, string> {
  const token = Cypress.env("API_TOKEN");
  const h: Record<string, string> = { "Content-Type": "application/json" };
  if (token) h["Authorization"] = `Bearer ${token}`;
  return h;
}

describe("MCP servers — add and list", () => {
  after(() => {
    cy.request({
      method: "DELETE",
      url: `/api/v1/mcpservers/${SERVER}?namespace=default`,
      headers: authHeaders(),
      failOnStatusCode: false,
    });
  });

  it("creates an MCP server via API and it appears in the UI", () => {
    cy.request({
      method: "POST",
      url: "/api/v1/mcpservers?namespace=default",
      headers: authHeaders(),
      body: {
        name: SERVER,
        transportType: "http",
        toolsPrefix: "cy",
        url: "http://example.invalid/sse",
      },
      failOnStatusCode: false,
    });

    cy.visit("/mcp-servers");
    cy.contains(SERVER, { timeout: 20000 }).should("be.visible");
  });
});

export {};
