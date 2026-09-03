-- Keep the member's visible current-month savings in sync when an admin changes it.
create or replace function public.set_monthly_savings_amount(p_member_id uuid, p_amount numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Only admins may set a monthly savings amount.';
  end if;
  if p_amount < 0 then
    raise exception 'Amount cannot be negative.';
  end if;

  update public.profiles set
    monthly_savings_amount = p_amount,
    last_savings_amount = p_amount,
    next_savings_amount = p_amount,
    last_savings_date = current_date,
    next_savings_date = current_date
  where id = p_member_id;
end;
$$;
