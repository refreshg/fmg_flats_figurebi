# -*- coding: utf-8 -*-
from odoo import api, models


class CrmLead(models.Model):
    _inherit = "crm.lead"

    def _figurebi_lang_managers(self):
        params = self.env["ir.config_parameter"].sudo()
        en_id = int(params.get_param("figurebi.en_manager_id") or 0)
        ka_id = int(params.get_param("figurebi.ka_manager_id") or 0)
        Users = self.env["res.users"].sudo()
        return (
            Users.browse(en_id) if en_id else Users,
            Users.browse(ka_id) if ka_id else Users,
        )

    def _figurebi_assign_by_lang(self):
        # en* leads -> EN manager, everything else (ka / empty / other) -> KA
        # manager (default). A salesperson deliberately chosen by the operator
        # (someone other than themselves or the two managers) is respected.
        if self.env.context.get("figurebi_crm_assign"):
            return
        en_user, ka_user = self._figurebi_lang_managers()
        if not en_user or not ka_user:
            return  # not configured in Settings yet
        for lead in self:
            if (lead.user_id and lead.user_id.id != self.env.uid
                    and lead.user_id.id not in (en_user.id, ka_user.id)):
                continue
            code = (lead.lang_id.code or "") if lead.lang_id else ""
            target = en_user if code.startswith("en") else ka_user
            if lead.user_id.id != target.id:
                lead.with_context(figurebi_crm_assign=True).write({"user_id": target.id})

    @api.model_create_multi
    def create(self, vals_list):
        leads = super().create(vals_list)
        leads._figurebi_assign_by_lang()
        return leads

    def write(self, vals):
        res = super().write(vals)
        if "lang_id" in vals:
            self._figurebi_assign_by_lang()
        return res
