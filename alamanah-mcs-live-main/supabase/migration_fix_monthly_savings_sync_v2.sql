-- Keep member-facing current savings fields synchronized whenever admin changes monthly savings.
CREATE OR REPLACE FUNCTION public.sync_member_monthly_savings_fields()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.monthly_savings_amount IS DISTINCT FROM OLD.monthly_savings_amount THEN
    NEW.last_savings_amount := NEW.monthly_savings_amount;
    NEW.next_savings_amount := NEW.monthly_savings_amount;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_member_monthly_savings_fields ON public.profiles;
CREATE TRIGGER trg_sync_member_monthly_savings_fields
BEFORE UPDATE OF monthly_savings_amount ON public.profiles
FOR EACH ROW EXECUTE FUNCTION public.sync_member_monthly_savings_fields();
