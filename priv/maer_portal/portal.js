(() => {
  "use strict";

  const form = document.querySelector("[data-fragment-form]");
  if (!form) return;

  const token = window.location.hash.slice(1);
  const input = form.querySelector("[data-fragment-token]");
  const submit = form.querySelector("[data-fragment-submit]");
  const status = form.querySelector("[data-fragment-status]");
  const valid = /^[A-Za-z0-9_-]{43}$/.test(token);

  history.replaceState(null, "", window.location.pathname);
  if (valid) {
    input.value = token;
    submit.disabled = false;
    status.textContent = "Lien prêt. Vous pouvez confirmer.";
    status.className = "status success";
  } else {
    input.value = "";
    submit.disabled = true;
    status.textContent = "Le lien ne contient pas de jeton valide.";
    status.className = "status pending";
  }
})();
