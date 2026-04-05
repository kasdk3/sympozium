// Regression guard: the run detail page MUST display status.result when it
// is populated on the CR. Directly guards against the session-discovered bug
// where LM Studio runs emitted output tokens but the UX showed "No result
// available" (because the response field was silently dropped).

const INSTANCE = `cy-runvis-${Date.now()}`;
let RUN_NAME = "";

describe("Run Detail — response visibility", () => {
  before(() => {
    cy.createLMStudioInstance(INSTANCE);
  });

  after(() => {
    if (RUN_NAME) cy.deleteRun(RUN_NAME);
    cy.deleteInstance(INSTANCE);
  });

  it("shows status.result text on the Result tab when populated", () => {
    cy.dispatchRun(INSTANCE, "Reply with exactly: RESPONSE_VISIBLE_OK").then((name) => {
      RUN_NAME = name;
      cy.waitForRunTerminal(name).then((phase) => {
        expect(phase).to.eq("Succeeded");
      });
    });

    // Navigate to the run detail.
    cy.then(() => {
      cy.visit(`/runs/${RUN_NAME}`);
    });

    // Result tab selected by default (or click it).
    cy.contains("button", "Result", { timeout: 20000 }).click({ force: true });

    // The markdown content should be rendered.
    cy.contains("RESPONSE_VISIBLE_OK", { timeout: 20000 }).should("be.visible");

    // And the "No result available" fallback must NOT be showing.
    cy.contains("No result available").should("not.exist");
  });
});

export {};
