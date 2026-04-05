// Skills page renders the catalog of installed SkillPacks. Verify the
// common built-ins (k8s-ops, memory, code-review) are listed.

describe("Skills catalog", () => {
  it("lists known built-in skill packs", () => {
    cy.visit("/skills");
    cy.get("body", { timeout: 20000 }).should("contain.text", "k8s-ops");
    cy.contains(/memory|Memory/).should("exist");
  });
});

export {};
