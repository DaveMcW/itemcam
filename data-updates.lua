-- Add script trigger to item projectiles
for _, projectile in pairs(data.raw["projectile"]) do
  if not projectile.created_effect then

    -- Check if an item produces this projectile
    for _, ammo in pairs(data.raw["ammo"]) do
      if ammo.ammo_type
      and ammo.ammo_type.action
      and ammo.ammo_type.action.action_delivery
      and ammo.ammo_type.action.action_delivery.type == "projectile"
      and ammo.ammo_type.action.action_delivery.projectile == projectile.name then

        -- Add script trigger
        projectile.created_effect = {
          type = "direct",
          action_delivery = {
            type = "instant",
            source_effects = {
              type = "script",
              effect_id = "itemcam-projectile-created"
            }
          }
        }

      end
    end
  end
end
