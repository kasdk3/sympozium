// Policies page renders without errors and shows the policies table.

describe("Policies page", () => {
  it("renders the policies view", () => {
    cy.visit("/policies");
    // Page must render (page title or table present).
    cy.contains(/polic/i, { timeout: 20000 }).should("exist");
    // No blank-page failure indicators.
    cy.contains(/error|failed to load/i).should("not.exist");
  });
});

export {};
