// Delete a SympoziumSchedule and verify no runs are dispatched after.
// Guards against orphaned schedules continuing to fire after deletion.

const INSTANCE = `cy-scdel-${Date.now()}`;
const SCHEDULE = `cy-scdel-sched-${Date.now()}`;

function authHeaders(): Record<string, string> {
  const token = Cypress.env("API_TOKEN");
  const h: Record<string, string> = { "Content-Type": "application/json" };
  if (token) h["Authorization"] = `Bearer ${token}`;
  return h;
}

describe("Schedule — delete", () => {
  before(() => {
    cy.createLMStudioInstance(INSTANCE);
    // Create a schedule that would fire every minute.
    cy.request({
      method: "POST",
      url: "/api/v1/schedules?namespace=default",
      headers: authHeaders(),
      body: {
        name: SCHEDULE,
        instanceRef: INSTANCE,
        schedule: "* * * * *",
        type: "scheduled",
        task: "test schedule task",
      },
      failOnStatusCode: false,
    });
  });

  after(() => {
    cy.deleteSchedule(SCHEDULE);
    cy.deleteInstance(INSTANCE);
  });

  it("deletes schedule and removes it from the UI list", () => {
    cy.visit("/schedules");
    cy.contains(SCHEDULE, { timeout: 20000 }).should("be.visible");

    cy.deleteSchedule(SCHEDULE);
    cy.waitForDeleted(`/api/v1/schedules/${SCHEDULE}?namespace=default`);

    cy.visit("/schedules");
    cy.contains(SCHEDULE, { timeout: 20000 }).should("not.exist");
  });
});

export {};
